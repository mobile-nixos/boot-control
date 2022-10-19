#!/usr/bin/env nix-shell
#!nix-shell -p ruby -i ruby
#!nix-shell -p gptfdisk

require "shellwords"

def get_output(*cmd, no_stderr: false, silent: true)
  redirection = " 2> /dev/null" if no_stderr
  runs = cmd.map(&:to_s).map(&:shellescape).join(" ")
  puts " $ #{runs}#{redirection}" unless silent
  `#{runs}#{redirection}`
end

# MVP bitfield helper class
class Bitfield
  def initialize(number, width: 64)
    @number = number
    @width = width
  end

  # Pretty-formats the bitfield
  def to_s()
    @number.to_s(2).rjust(@width, "0").scan(/.{8}/).join(":")
  end

  def to_i()
    @number
  end

  def get_bit(n)
    raise "Bit #{n} reaches outside the width of #{@width} bits." if n >= @width
    bit = @number.to_s(2).rjust(@width, "0").chars.reverse[n].to_i
  end
  
  def [](n)
    get_bit(n)
  end
end

class GPT
  SGDISK = "sgdisk"

  def sgdisk(*cmd)
    get_output(SGDISK, "--pretend", *cmd, no_stderr: true, silent: true)
  end

  def initialize(disk)
    @disk = disk
  end

  def part_info(part)
    # {"Partition GUID code"=>"77036CD4-03D5-42BB-8ED1-37E5A88BAA34 (Unknown)",
    #  "Partition unique GUID"=>"326AD371-C287-2DC5-FFA8-CD86CEC4BF5D",
    #  "First sector"=>"54150 (at 211.5 MiB)",
    #  "Last sector"=>"70533 (at 275.5 MiB)",
    #  "Partition size"=>"16384 sectors (64.0 MiB)",
    #  "Attribute flags"=>"003B000000000000",
    #  "Partition name"=>"'boot_a'"}
    info = sgdisk(@disk, "--info", part).split(/\*+\n/).last
      .lines.map {|line| line.strip.split(/:\s+/, 2)}
      .to_h

    attributes = info["Attribute flags"].split(/\s/).first
    attributes = Integer(attributes, 16)

    {
      guid: info["Partition GUID code"].split(/\s/).first,
      uuid: info["Partition unique GUID"].split(/\s/).first,
      first_sector: info["First sector"].split(/\s/).first.to_i,
      last_sector: info["Last sector"].split(/\s/).first.to_i,
      size: info["Partition size"].split(/\s/).first.to_i,
      attributes: Bitfield.new(attributes),
      name: info["Partition name"].sub(/^'/, "").sub(/'$/, ""),
    }
  end
end


class Partition
  def self.refresh_labels_map()
    @@labels_map = Dir.glob("/dev/disk/by-partlabel/*").map do |path|
      [
        path.split("/").last,
        File.realpath(path)
      ]
    end.to_h
  end
  # This strongly assumes the mapping is static.
  refresh_labels_map()

  def self.by_partlabel(partlabel)
    path = @@labels_map[partlabel]
    num = path.match(/[0-9]+$/)[0]
    disk = path.match(/^[^0-9]+/)[0]

    self.new(disk, num)
  end

  def initialize(disk, num)
    @disk = disk
    @num = num
    @gpt = GPT.new(disk)
  end

  def info()
    @gpt.part_info(@num)
  end

  def sgdisk(*cmd)
    get_output(GPT::SGDISK, *cmd, @disk)
  end

  def sgdisk_attributes(stanza)
    raise "Stanza is probably bad: #{stanza}" if stanza.match(/\s/)
    sgdisk("--attributes=#{@num}:#{stanza}")
  end
end


# https://android.googlesource.com/platform/hardware/libhardware/+/master/include/hardware/boot_control.h
module AndroidBootControl
  extend self

  def booted_slot_suffix()
    File.read("/proc/cmdline").split(/\s+/).grep(/^androidboot.slot_suffix=/).first.split("=").last
  end
end

#
# This works on the the 2nd most significant _byte_ of the GPT partition
# attribute flag.
#
# Here it is shown in binary:
#
# ```
# 00000000 01110111 00000000 00000000 00000000 00000000 00000000 00000000
#          ^^^^^^^^
# ```
#
# The values, from most significant bit to least significant
#
# - 1 bit:   unbootable flag  (bit 55)
# - 1 bit:   successful flag  (bit 54)
# - 3 bits:  tries count      (bit 51, 52, 53)
# - 1 bit:   active flag      (bit 50)
# - 2 bits:  [unknown]        (bit 48, 49)
# 
# ```
# usccca__
# 01110111
# ```
# 
# In this current example, the boot is marked as successful, and there are 6
# tries left before the bootloader marks it unbootable. 
#
# References:
#  - https://github.com/LineageOS/android_hardware_qcom_bootctrl/blob/69f2d8d08699fdec49605c6b95fc06163952b6fa/boot_control.cpp#L212-L227
#  - https://github.com/LineageOS/android_device_google_bonito/blob/4f1b691694a1788941cad03dba95102d93437654/gpt-utils/gpt-utils.h#L65-L88
module QualcommGPTBootControl
  include AndroidBootControl
  extend self

  # From the 48th bit
  ATTRIBUTE_FLAGS_START = 48
  # One uint8_t worth
  ATTRIBUTE_FLAGS_END   = ATTRIBUTE_FLAGS_START + 8

  AB_PARTITION_ATTR_SLOT_ACTIVE     = (0x1<<2)
  AB_PARTITION_ATTR_BOOT_SUCCESSFUL = (0x1<<6)
  AB_PARTITION_ATTR_UNBOOTABLE      = (0x1<<7)
  AB_SLOT_ACTIVE_VAL                = 0x1F
  AB_SLOT_INACTIVE_VAL              = 0x0

  # FIXME: this only works on the active boot partition.
  def part()
    Partition.by_partlabel("boot" + booted_slot_suffix)
  end

  def private_bits()
    attributes = part.info[:attributes]
    bits = (attributes.to_i>>ATTRIBUTE_FLAGS_START) % (0x1<<8)
    Bitfield.new(bits, width: 8)
  end

  # FIXME: this only checks the active boot partition.
  def active?()
    private_bits[AB_PARTITION_ATTR_SLOT_ACTIVE.to_s(2).length-1] == 1
  end

  # FIXME: this only checks the active boot partition.
  def boot_successful?()
    private_bits[AB_PARTITION_ATTR_BOOT_SUCCESSFUL.to_s(2).length-1] == 1
  end

  def unbootable?()
    private_bits[AB_PARTITION_ATTR_UNBOOTABLE.to_s(2).length-1] == 1
  end

  def tries_remaining()
    (private_bits.to_i >> 3) % (0x1<<3)
  end

  def boot_successful=(val)
    val = if val then 1 else 0 end
    part.sgdisk_attributes("set:54")
  end
end

def report()
  puts "Tries remaining: #{QualcommGPTBootControl.tries_remaining}"
  puts "    unbootable?: #{QualcommGPTBootControl.unbootable?}"
  puts "        active?: #{QualcommGPTBootControl.active?}"
  puts "    successful?: #{QualcommGPTBootControl.boot_successful?}"
  puts ""
end

report()

if ARGV.first == "--mark-successful"
  if QualcommGPTBootControl.boot_successful? then
    puts "Already successful, doing nothing..."
  else
    puts "Marking successful..."
    QualcommGPTBootControl.boot_successful = true
    # Print the report again
    report()
  end
end
