# encoding: ascii-8bit

# Copyright 2021 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU Affero General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# This program may also be used under the terms of a commercial or
# enterprise edition license of COSMOS if purchased from the
# copyright holder

require 'cosmos/io/io_multiplexer'

module Cosmos
  # Adds STDERR to the multiplexed streams
  class Stderr < IoMultiplexer
    @@instance = nil

    def initialize
      super()
      @streams << STDERR
      @@instance = self
    end

    # @return [Stderr] Returns a single instance of Stderr
    def self.instance
      self.new unless @@instance
      @@instance
    end

    def tty?
      false
    end
  end
end
