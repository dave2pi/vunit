-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Copyright (c) 2017, Lars Asplund lars.anders.asplund@gmail.com

library ieee;
use ieee.std_logic_1164.all;

use work.queue_pkg.all;
use work.fail_pkg.all;
context work.com_context;

package bus_pkg is
  alias bus_reference_t is message_ptr_t;

  type bus_t is record
    -- Private
    p_actor : actor_t;
    p_data_length : natural;
    p_address_length : natural;
    p_fail_log : fail_log_t;
  end record;

  type bus_access_type_t is (read_access, write_access);
  type bus_request_t is record
    access_type : bus_access_type_t;
    address     : std_logic_vector;
    data        : std_logic_vector;
  end record bus_request_t;

  procedure decode (variable request_msg : inout message_ptr_t; variable bus_request : inout bus_request_t);

  impure function new_bus(data_length, address_length : natural; name : string := "") return bus_t;
  impure function data_length(bus_handle : bus_t) return natural;
  impure function address_length(bus_handle : bus_t) return natural;

  procedure write_bus(signal event : inout event_t;
                      constant bus_handle : bus_t;
                      constant address : std_logic_vector;
                      constant data : std_logic_vector);

  -- Non blocking read with delayed reply
  procedure read_bus(signal event : inout event_t;
                     constant bus_handle : bus_t;
                     constant address : std_logic_vector;
                     variable reference : inout bus_reference_t);

  -- Await read bus reply
  procedure await_read_bus_reply(signal event : inout event_t;
                                 variable reference : inout bus_reference_t;
                                 variable data : inout std_logic_vector);

  -- Blocking read and check result
  procedure check_bus(signal event : inout event_t;
                      constant bus_handle : bus_t;
                      constant address : std_logic_vector;
                      constant expected : std_logic_vector;
                      constant mask : std_logic_vector := "";
                      constant msg : string := "");

  -- Blocking read with immediate reply
  procedure read_bus(signal event : inout event_t;
                     constant bus_handle : bus_t;
                     constant address : std_logic_vector;
                     variable data : inout std_logic_vector);

  -- Wait until a read from address equals the value in the positions defined by the mask bit
  -- If timeout is reached error with msg
  procedure wait_until_read_equals(
    signal event : inout event_t;
    bus_handle   : bus_t;
    addr         : std_logic_vector;
    value        : std_logic_vector;
    mask         : std_logic_vector;
    timeout      : delay_length := delay_length'high;
    msg    : string       := "");

  -- Wait until a read from address has the bit with this index set to value
  -- If timeout is reached error with msg
  procedure wait_until_read_bit_equals(
    signal event : inout event_t;
    bus_handle   : bus_t;
    addr         : std_logic_vector;
    idx          : natural;
    value        : std_logic;
    timeout      : delay_length := delay_length'high;
    msg    : string       := "");

end package;

package body bus_pkg is
  procedure decode (variable request_msg : inout message_ptr_t; variable bus_request : inout bus_request_t) is
    variable index : positive;
  begin
    index := request_msg.payload.all'left;
    bus_request.access_type := bus_access_type_t'val(character'pos(request_msg.payload.all(index)));
    index := index + 1;
    decode(request_msg.payload.all, index, bus_request.address);
    if bus_request.access_type = write_access then
        decode(request_msg.payload.all, index, bus_request.data);
    end if;
  end;

  impure function new_bus(data_length, address_length : natural; name : string := "") return bus_t is
  begin
    return (p_actor => create(name),
            p_data_length => data_length,
            p_address_length => address_length,
            p_fail_log => new_fail_log);
  end;

  impure function data_length(bus_handle : bus_t) return natural is
  begin
    return bus_handle.p_data_length;
  end;

  impure function address_length(bus_handle : bus_t) return natural is
  begin
    return bus_handle.p_address_length;
  end;

  procedure write_bus(signal event : inout event_t;
                      constant bus_handle : bus_t;
                      constant address : std_logic_vector;
                      constant data : std_logic_vector) is
    variable full_data : std_logic_vector(bus_handle.p_data_length-1 downto 0) := (others => '0');
    variable full_address : std_logic_vector(bus_handle.p_address_length-1 downto 0) := (others => '0');
  begin
    full_data(data'length-1 downto 0) := data;
    full_address(address'length-1 downto 0) := address;
    send(event, bus_handle.p_actor,
         character'val(bus_access_type_t'pos(write_access)) & encode(full_address) & encode(full_data));
  end procedure;

  procedure check_bus(signal event : inout event_t;
                      constant bus_handle : bus_t;
                      constant address : std_logic_vector;
                      constant expected : std_logic_vector;
                      constant mask : std_logic_vector := "";
                      constant msg : string := "") is
    variable data : std_logic_vector(bus_handle.p_data_length-1 downto 0);
    variable edata : std_logic_vector(data'range) := (others => '0');
    variable full_mask : std_logic_vector(data'range) := (others => '0');

    impure function error_prefix return string is
    begin
      if msg = "" then
        return "check_bus(x""" & to_hstring(address) & """)";
      else
        return msg;
      end if;
    end;

    impure function base_error return string is
    begin
      return error_prefix & " - Got x""" & to_hstring(data) & """ expected x""" & to_hstring(edata) & """";
    end;
  begin

    edata(expected'length-1 downto 0) := expected;
    if mask = "" then
      full_mask := (others => '1');
    else
      full_mask(mask'length-1 downto 0) := mask;
    end if;

    read_bus(event, bus_handle, address, data);
    if (data and full_mask) /= (edata and full_mask) then
      if mask = "" then
        fail(bus_handle.p_fail_log, base_error);
      else
        fail(bus_handle.p_fail_log, base_error & " using mask x""" & to_hstring(full_mask) & """");
      end if;
    end if;
  end procedure;

  -- Non blocking read with delayed reply
  procedure read_bus(signal event : inout event_t;
                     constant bus_handle : bus_t;
                     constant address : std_logic_vector;
                     variable reference : inout bus_reference_t) is
    variable full_address : std_logic_vector(bus_handle.p_address_length-1 downto 0) := (others => '0');
  begin
    full_address(address'length-1 downto 0) := address;
    reference := compose(character'val(bus_access_type_t'pos(read_access)) & encode(full_address));
    send(event, bus_handle.p_actor, reference);
  end procedure;

  -- Await read bus reply
  procedure await_read_bus_reply(signal event : inout event_t;
                                 variable reference : inout bus_reference_t;
                                 variable data : inout std_logic_vector) is
    variable msg : message_ptr_t;
  begin
    receive_reply(event, reference, msg);
    data := decode(msg.payload.all);
    delete(reference);
    delete(msg);
  end procedure;

  -- Blocking read with immediate reply
  procedure read_bus(signal event : inout event_t;
                     constant bus_handle : bus_t;
                     constant address : std_logic_vector;
                     variable data : inout std_logic_vector) is
    variable reference : bus_reference_t;
  begin
    read_bus(event, bus_handle, address, reference);
    await_read_bus_reply(event, reference, data);
  end procedure;


  procedure wait_until_read_equals(
    signal event : inout event_t;
    bus_handle   : bus_t;
    addr         : std_logic_vector;
    value        : std_logic_vector;
    mask         : std_logic_vector;
    timeout      : delay_length := delay_length'high;
    msg    : string       := "") is
    constant start_time : time         := now;
    variable waited     : delay_length := delay_length'low;
    variable data       : std_logic_vector(bus_handle.p_data_length-1 downto 0);
  begin
    while waited <= timeout loop
      -- Do the waited calculation here so that a read delay is allowed when
      -- timeout is set to zero.
      waited := now - start_time;
      read_bus(event, bus_handle, addr, data);
      if (data(value'length-1 downto 0) and mask) = (value and mask) then
        return;
      end if;
    end loop;

    if msg = "" then
      fail(bus_handle.p_fail_log, "Timeout");
    else
      fail(bus_handle.p_fail_log, msg);
    end if;
  end;

  procedure wait_until_read_bit_equals(
    signal event : inout event_t;
    bus_handle   : bus_t;
    addr         : std_logic_vector;
    idx          : natural;
    value        : std_logic;
    timeout      : delay_length := delay_length'high;
    msg    : string       := "") is
    variable data, mask : std_logic_vector(bus_handle.p_data_length-1 downto 0);
  begin
    data      := (others => '0');
    mask      := (others => '0');
    data(idx) := value;
    mask(idx) := '1';
    wait_until_read_equals(event, bus_handle, addr, data, mask, timeout, msg);
  end;

end package body;
