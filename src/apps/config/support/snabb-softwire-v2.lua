-- Use of this source code is governed by the Apache 2.0 license; see COPYING.
module(..., package.seeall)
local ffi = require('ffi')
local app = require('core.app')
local corelib = require('core.lib')
local equal = require('core.lib').equal
local dirname = require('core.lib').dirname
local data = require('lib.yang.data')
local ipv4_ntop = require('lib.yang.util').ipv4_ntop
local ipv6 = require('lib.protocol.ipv6')
local yang = require('lib.yang.yang')
local ctable = require('lib.ctable')
local cltable = require('lib.cltable')
local path_mod = require('lib.yang.path')
local generic = require('apps.config.support').generic_schema_config_support
local binding_table = require("apps.lwaftr.binding_table")

local binding_table_instance
local function get_binding_table_instance(conf)
   if binding_table_instance == nil then
      binding_table_instance = binding_table.load(conf)
   end
   return binding_table_instance
end

-- Packs snabb-softwire-v2 softwire entry into softwire and PSID blob
--
-- The data plane stores a separate table of psid maps and softwires. It
-- requires that we give it a blob it can quickly add. These look rather
-- similar to snabb-softwire-v1 structures however it maintains the br-address
-- on the softwire so are subtly different.
local function pack_softwire(app_graph, key, value)
   assert(app_graph.apps['lwaftr'])
   assert(value.port_set, "Softwire lacks port-set definition")

   -- Get the binding table
   local bt_conf = app_graph.apps.lwaftr.arg.softwire_config.binding_table
   bt = get_binding_table_instance(bt_conf)

   local softwire_t = bt.softwires.entry_type()
   psid_map_t = bt.psid_map.entry_type()

   -- Now lets pack the stuff!
   local packed_softwire = ffi.new(softwire_t)
   packed_softwire.key.ipv4 = key.ipv4
   packed_softwire.key.psid = key.psid
   packed_softwire.key.padding = key.padding
   packed_softwire.value.b4_ipv6 = value.b4_ipv6
   packed_softwire.value.br_address = value.br_address

   local packed_psid_map = ffi.new(psid_map_t)
   packed_psid_map.key.addr = key.ipv4
   if value.port_set.psid_length then
      packed_psid_map.value.psid_length = value.port_set.psid_length
   end
   if value.port_set.shift then
      packed_psid_map.value.shift = value.port_set.shift
   end

   return packed_softwire, packed_psid_map
end

local function add_softwire_entry_actions(app_graph, entries)
   assert(app_graph.apps['lwaftr'])
   local bt_conf = app_graph.apps.lwaftr.arg.softwire_config.binding_table
   local bt = get_binding_table_instance(bt_conf)
   local ret = {}
   for key, entry in cltable.pairs(entries) do
      local psoftwire, ppsid = pack_softwire(app_graph, key, entry)
      local softwire_args = {'lwaftr', 'add_softwire_entry', psoftwire}
      table.insert(ret, {'call_app_method_with_blob', softwire_args})
      if bt.psid_map:lookup_ptr(ppsid) == nil then
         local psid_map_args = {'lwaftr', 'add_psid_map_entry', ppsid}
         table.insert(ret, {'call_app_method_with_blob', psid_map_args})
      end
   end
   table.insert(ret, {'commit', {}})
   return ret
end

local softwire_grammar
local function get_softwire_grammar()
   if not softwire_grammar then
      local schema = yang.load_schema_by_name('snabb-softwire-v2')
      local grammar = data.data_grammar_from_schema(schema)
      softwire_grammar =
         assert(grammar.members['softwire-config'].
                   members['binding-table'].members['softwire'])
   end
   return softwire_grammar
end

local function remove_softwire_entry_actions(app_graph, path)
   assert(app_graph.apps['lwaftr'])
   path = path_mod.parse_path(path)
   local grammar = get_softwire_grammar()
   local key = path_mod.prepare_table_lookup(
      grammar.keys, grammar.key_ctype, path[#path].query)
   local args = {'lwaftr', 'remove_softwire_entry', key}
   -- If it's the last softwire for the corresponding psid entry, remove it.
   -- TODO: check if last psid entry and then remove.
   return {{'call_app_method_with_blob', args}, {'commit', {}}}
end

local function compute_config_actions(old_graph, new_graph, to_restart,
                                      verb, path, arg)
   -- If the binding cable changes, remove our cached version.
   if path ~= nil and path:match("^/softwire%-config/binding%-table") then
      binding_table_instance = nil
   end

   if verb == 'add' and path == '/softwire-config/binding-table/softwire' then
      return add_softwire_entry_actions(new_graph, arg)
   elseif (verb == 'remove' and
           path:match('^/softwire%-config/binding%-table/softwire')) then
      return remove_softwire_entry_actions(new_graph, path)
   elseif (verb == 'set' and path == '/softwire-config/name') then
      return {}
   else
      return generic.compute_config_actions(
         old_graph, new_graph, to_restart, verb, path, arg)
   end
end

local function update_mutable_objects_embedded_in_app_initargs(
      in_place_dependencies, app_graph, schema_name, verb, path, arg)
   if verb == 'add' and path == '/softwire-config/binding-table/softwire' then
      return in_place_dependencies
   elseif (verb == 'remove' and
           path:match('^/softwire%-config/binding%-table/softwire')) then
      return in_place_dependencies
   else
      return generic.update_mutable_objects_embedded_in_app_initargs(
         in_place_dependencies, app_graph, schema_name, verb, path, arg)
   end
end

local function compute_apps_to_restart_after_configuration_update(
      schema_name, configuration, verb, path, in_place_dependencies)
   if verb == 'add' and path == '/softwire-config/binding-table/softwire' then
      return {}
   elseif (verb == 'remove' and
           path:match('^/softwire%-config/binding%-table/softwire')) then
      return {}
   elseif (verb == 'set' and path == '/softwire-config/name') then
      return {}
   else
      return generic.compute_apps_to_restart_after_configuration_update(
         schema_name, configuration, verb, path, in_place_dependencies)
   end
end

local function memoize1(f)
   local memoized_arg, memoized_result
   return function(arg)
      if arg == memoized_arg then return memoized_result end
      memoized_result = f(arg)
      memoized_arg = arg
      return memoized_result
   end
end

local ietf_br_instance_grammar
local function get_ietf_br_instance_grammar()
   if not ietf_br_instance_grammar then
      local schema = yang.load_schema_by_name('ietf-softwire')
      local grammar = data.data_grammar_from_schema(schema)
      grammar = assert(grammar.members['softwire-config'])
      grammar = assert(grammar.members['binding'])
      grammar = assert(grammar.members['br'])
      grammar = assert(grammar.members['br-instances'])
      grammar = assert(grammar.members['br-instance'])
      ietf_br_instance_grammar = grammar
   end
   return ietf_br_instance_grammar
end

local ietf_softwire_grammar
local function get_ietf_softwire_grammar()
   if not ietf_softwire_grammar then
      local grammar = get_ietf_br_instance_grammar()
      grammar = assert(grammar.values['binding-table'])
      grammar = assert(grammar.members['binding-entry'])
      ietf_softwire_grammar = grammar
   end
   return ietf_softwire_grammar
end

local function cltable_for_grammar(grammar)
   assert(grammar.key_ctype)
   assert(not grammar.value_ctype)
   local key_t = data.typeof(grammar.key_ctype)
   return cltable.new({key_type=key_t}), key_t
end

local function ietf_binding_table_from_native(bt)
   local ret, key_t = cltable_for_grammar(get_ietf_softwire_grammar())
   local psid_key_t = data.typeof('struct { uint32_t ipv4; }')
   for entry in bt.softwire:iterate() do
      local psid_map = bt.psid_map[psid_key_t({ipv4=entry.key.ipv4})]
      if psid_map then
         local k = key_t({ binding_ipv6info = entry.value.b4_ipv6 })
         local v = {
            binding_ipv4_addr = entry.key.ipv4,
            port_set = {
               psid_offset = psid_map.reserved_ports_bit_count,
               psid_len = psid_map.psid_length,
               psid = entry.key.psid
            },
            br_ipv6_addr = entry.value.br_address,
         }
         ret[k] = v
      end
   end
   return ret
end

local function schema_getter(schema_name, path)
   local schema = yang.load_schema_by_name(schema_name)
   local grammar = data.data_grammar_from_schema(schema)
   return path_mod.resolver(grammar, path)
end

local function snabb_softwire_getter(path)
   return schema_getter('snabb-softwire-v2', path)
end

local function ietf_softwire_getter(path)
   return schema_getter('ietf-softwire', path)
end

local function native_binding_table_from_ietf(ietf)
   local _, psid_map_grammar =
      snabb_softwire_getter('/softwire-config/binding-table/psid-map')
   local psid_map_key_t = data.typeof(psid_map_grammar.key_ctype)
   local psid_map = cltable.new({key_type=psid_map_key_t})
   local br_address = {}
   local br_address_by_ipv6 = {}
   local _, softwire_grammar =
      snabb_softwire_getter('/softwire-config/binding-table/softwire')
   local softwire_key_t = data.typeof(softwire_grammar.key_ctype)
   local softwire_value_t = data.typeof(softwire_grammar.value_ctype)
   local softwire = ctable.new({key_type=softwire_key_t,
                                value_type=softwire_value_t})
   for k,v in cltable.pairs(ietf) do
      local psid_key = psid_map_key_t({addr=v.binding_ipv4_addr})
      if not psid_map[psid_key] then
         psid_map[psid_key] = {psid_length=v.port_set.psid_len,
                               reserved_ports_bit_count=v.port_set.psid_offset}
      end
      softwire:add(softwire_key_t({ipv4=v.binding_ipv4_addr,
                                   psid=v.port_set.psid}),
                   softwire_value_t({br_address=v.br_ipv6_addr, b4_ipv6=k.binding_ipv6info}))
   end
   return {psid_map=psid_map, softwire=softwire}
end

local function serialize_binding_table(bt)
   local _, grammar = snabb_softwire_getter('/softwire-config/binding-table')
   local printer = data.data_printer_from_grammar(grammar)
   return printer(bt, yang.string_output_file())
end

local uint64_ptr_t = ffi.typeof('uint64_t*')
function ipv6_equals(a, b)
   local x, y = ffi.cast(uint64_ptr_t, a), ffi.cast(uint64_ptr_t, b)
   return x[0] == y[0] and x[1] == y[1]
end

local function ietf_softwire_translator ()
   local ret = {}
   local cached_config
   function ret.get_config(native_config)
      if cached_config ~= nil then return cached_config end
      local br_instance, br_instance_key_t =
         cltable_for_grammar(get_ietf_br_instance_grammar())
      br_instance[br_instance_key_t({id=1})] = {
         name = native_config.softwire_config.name,
         tunnel_payload_mtu = native_config.softwire_config.internal_interface.mtu,
         tunnel_path_mru = native_config.softwire_config.external_interface.mtu,
         -- FIXME: There's no equivalent of softwire-num-threshold in snabb-softwire-v1.
         softwire_num_threshold = 0xffffffff,
         binding_table = {
            binding_entry = ietf_binding_table_from_native(
               native_config.softwire_config.binding_table)
         }
      }
      cached_config = {
         softwire_config = {
            binding = {
               br = {
                  br_instances = { br_instance = br_instance }
               }
            }
         }
      }
      return cached_config
   end
   function ret.get_state(native_state)
      -- Even though this is a different br-instance node, it is a
      -- cltable with the same key type, so just re-use the key here.
      local br_instance, br_instance_key_t =
         cltable_for_grammar(get_ietf_br_instance_grammar())
      br_instance[br_instance_key_t({id=1})] = {
         -- FIXME!
         sentPacket = 0,
         sentByte = 0,
         rcvdPacket = 0,
         rcvdByte = 0,
         droppedPacket = 0,
         droppedByte = 0
      }
      return {
         softwire_state = {
            binding = {
               br = {
                  br_instances = { br_instance = br_instance }
               }
            }
         }
      }
   end
   local function sets_whole_table(path, count)
      if #path > count then return false end
      if #path == count then
         for k,v in pairs(path[#path].query) do return false end
      end
      return true
   end
   function ret.set_config(native_config, path_str, arg)
      path = path_mod.parse_path(path_str)
      local br_instance_paths = {'softwire-config', 'binding', 'br',
                                 'br-instances', 'br-instance'}
      local bt_paths = {'binding-table', 'binding-entry'}

      -- Handle special br attributes (tunnel-payload-mtu, tunnel-path-mru, softwire-num-threshold).
      if #path > #br_instance_paths then
         if path[#path].name == 'tunnel-payload-mtu' then
            return {{'set', {schema='snabb-softwire-v2',
                     path="/softwire-config/internal-interface/mtu",
                     config=tostring(arg)}}}
         end
         if path[#path].name == 'tunnel-path-mru' then
            return {{'set', {schema='snabb-softwire-v2',
                     path="/softwire-config/external-interface/mtu",
                     config=tostring(arg)}}}
         end
         if path[#path].name == 'softwire-num-threshold' then
            error('not yet implemented: softwire-num-threshold')
         end
	 if path[#path].name == 'name' then
	    return {{'set', {schema='snabb-softwire-v1',
			    path="/softwire-config/name",
			    config=arg}}}
	 end
         error('unrecognized leaf: '..path[#path].name)
      end

      -- Two kinds of updates: setting the whole binding table, or
      -- updating one entry.
      if sets_whole_table(path, #br_instance_paths + #bt_paths) then
         -- Setting the whole binding table.
         if sets_whole_table(path, #br_instance_paths) then
            for i=#path+1,#br_instance_paths do
               arg = arg[data.normalize_id(br_instance_paths[i])]
            end
            local instance
            for k,v in cltable.pairs(arg) do
               if instance then error('multiple instances in config') end
               if k.id ~= 1 then error('instance id not 1: '..tostring(k.id)) end
               instance = v
            end
            if not instance then error('no instances in config') end
            arg = instance
         end
         for i=math.max(#path-#br_instance_paths,0)+1,#bt_paths do
            arg = arg[data.normalize_id(bt_paths[i])]
         end
         local bt = native_binding_table_from_ietf(arg)
         return {{'set', {schema='snabb-softwire-v2',
                          path='/softwire-config/binding-table',
                          config=serialize_binding_table(bt)}}}
      else
         -- An update to an existing entry.  First, get the existing entry.
         local config = ret.get_config(native_config)
         local entry_path = path_str
         local entry_path_len = #br_instance_paths + #bt_paths
         for i=entry_path_len+1, #path do
            entry_path = dirname(entry_path)
         end
         local old = ietf_softwire_getter(entry_path)(config)
         -- Now figure out what the new entry should look like.
         local new
         if #path == entry_path_len then
            new = arg
         else
            new = {
               port_set = {
                  psid_offset = old.port_set.psid_offset,
                  psid_len = old.port_set.psid_len,
                  psid = old.port_set.psid
               },
               binding_ipv4_addr = old.binding_ipv4_addr,
               br_ipv6_addr = old.br_ipv6_addr
            }
            if path[entry_path_len + 1].name == 'port-set' then
               if #path == entry_path_len + 1 then
                  new.port_set = arg
               else
                  local k = data.normalize_id(path[#path].name)
                  new.port_set[k] = arg
               end
            elseif path[#path].name == 'binding-ipv4-addr' then
               new.binding_ipv4_addr = arg
            elseif path[#path].name == 'br-ipv6-addr' then
               new.br_ipv6_addr = arg
            else
               error('bad path element: '..path[#path].name)
            end
         end
         -- Apply changes.  Ensure  that the port-set
         -- changes are compatible with the existing configuration.
         local updates = {}
         local softwire_path = '/softwire-config/binding-table/softwire'
         local psid_map_path = '/softwire-config/binding-table/psid-map'
         local bt = native_config.softwire_config.binding_table
         if new.binding_ipv4_addr ~= old.binding_ipv4_addr then
            local psid_key_t = data.typeof('struct { uint32_t ipv4; }')
            local psid_map_entry =
               bt.psid_map[psid_key_t({ipv4=new.binding_ipv4_addr})]
            if psid_map_entry == nil then
               local config_str = string.format(
                  "{ addr %s; psid-length %s; reserved-ports-bit-count %s; }",
                  ipv4_ntop(new.binding_ipv4_addr), new.port_set.psid_len,
                  new.port_set.psid_offset)
               table.insert(updates,
                            {'add', {schema='snabb-softwire-v2',
                                     path=psid_map_path,
                                     config=config_str}})
            elseif (psid_map_entry.psid_length ~= new.port_set.psid_len or
                    psid_map_entry.reserved_ports_bit_count ~=
                      new.port_set.psid_offset) then
               -- The Snabb lwAFTR is restricted to having the same PSID
               -- parameters for every softwire on an IPv4.  Here we
               -- have a request to have a softwire whose paramters
               -- differ from those already installed for this IPv4
               -- address.  We would need to verify that there is no
               -- other softwire on this address.
               error('changing psid params unimplemented')
            end
         elseif (new.port_set.psid_offset ~= old.port_set.psid_offset or
                 new.port_set.psid_len ~= old.port_set.psid_len) then
            -- See comment above.
            error('changing psid params unimplemented')
         end
         -- OK, psid_map taken care of, let's just remove
         -- this softwire entry and add a new one.
         local function q(ipv4, psid)
            return string.format('[ipv4=%s][psid=%s]', ipv4_ntop(ipv4), psid)
         end
         local old_query = q(old.binding_ipv4_addr, old.port_set.psid)
         -- FIXME: This remove will succeed but the add could fail if
         -- there's already a softwire with this IPv4 and PSID.  We need
         -- to add a check here that the IPv4/PSID is not present in the
         -- binding table.
         table.insert(updates,
                      {'remove', {schema='snabb-softwire-v2',
                                  path=softwire_path..old_query}})
         local config_str = string.format(
            '{ ipv4 %s; psid %s; br-address %s; b4-ipv6 %s; }',
            ipv4_ntop(new.binding_ipv4_addr), new.port_set.psid,
            ipv6:ntop(new.br_ipv6_addr),
            path[entry_path_len].query['binding-ipv6info'])
         table.insert(updates,
                      {'add', {schema='snabb-softwire-v2',
                               path=softwire_path,
                               config=config_str}})
         return updates
      end
   end
   function ret.add_config(native_config, path, data)
      if path ~= ('/softwire-config/binding/br/br-instances'..
                     '/br-instance[id=1]/binding-table/binding-entry') then
         error('unsupported path: '..path)
      end
      local config = ret.get_config(native_config)
      local ietf_bt = ietf_softwire_getter(path)(config)
      local old_bt = native_config.softwire_config.binding_table
      local new_bt = native_binding_table_from_ietf(data)
      local updates = {}
      local softwire_path = '/softwire-config/binding-table/softwire'
      local psid_map_path = '/softwire-config/binding-table/psid-map'
      -- Add new psid_map entries.
      for k,v in cltable.pairs(new_bt.psid_map) do
         if old_bt.psid_map[k] then
            if not equal(old_bt.psid_map[k], v) then
               error('changing psid params unimplemented: '..k.addr)
            end
         else
            local config_str = string.format(
               "{ addr %s; psid-length %s; reserved-ports-bit-count %s; }",
               ipv4_ntop(k.addr), v.psid_length, v.reserved_ports_bit_count)
            table.insert(updates,
                         {'add', {schema='snabb-softwire-v2',
                                  path=psid_map_path,
                                  config=config_str}})
         end
      end
      -- Add softwires.
      local additions = {}
      for entry in new_bt.softwire:iterate() do
         if old_bt.softwire:lookup_ptr(entry) then
            error('softwire already present in table: '..
                     inet_ntop(entry.key.ipv4)..'/'..entry.key.psid)
         end
         local config_str = string.format(
            '{ ipv4 %s; psid %s; br-address %s; b4-ipv6 %s; }',
            ipv4_ntop(entry.key.ipv4), entry.key.psid,
            ipv6:ntop(entry.value.br_address), ipv6:ntop(entry.value.b4_ipv6))
         table.insert(additions, config_str)
      end
      table.insert(updates,
                   {'add', {schema='snabb-softwire-v2',
                            path=softwire_path,
                            config=table.concat(additions, '\n')}})
      return updates
   end
   function ret.remove_config(native_config, path)
      local ietf_binding_table_path =
         '/softwire-config/binding/br/br-instances/br-instance[id=1]/binding-table'
      local softwire_path = '/softwire-config/binding-table/softwire'
      if (dirname(path) ~= ietf_binding_table_path or
          path:sub(-1) ~= ']') then
         error('unsupported path: '..path)
      end
      local config = ret.get_config(native_config)
      local entry = ietf_softwire_getter(path)(config)
      local function q(ipv4, psid)
         return string.format('[ipv4=%s][psid=%s]', ipv4_ntop(ipv4), psid)
      end
      local query = q(entry.binding_ipv4_addr, entry.port_set.psid)
      return {{'remove', {schema='snabb-softwire-v2',
                          path=softwire_path..query}}}
   end
   function ret.pre_update(native_config, verb, path, data)
      -- Given the notification that the native config is about to be
      -- updated, make our cached config follow along if possible (and
      -- if we have one).  Otherwise throw away our cached config; we'll
      -- re-make it next time.
      if cached_config == nil then return end
      if (verb == 'remove' and
          path:match('^/softwire%-config/binding%-table/softwire')) then
         -- Remove a softwire.
         local value = snabb_softwire_getter(path)(native_config)
         for _,instance in cltable.pairs(br.br_instances.br_instance) do
            local grammar = get_ietf_softwire_grammar()
            local key = path_mod.prepare_table_lookup(
               grammar.keys, grammar.key_ctype, {['binding-ipv6info']='::'})
            key.binding_ipv6info = value.b4_ipv6
            assert(instance.binding_table.binding_entry[key] ~= nil)
            instance.binding_table.binding_entry[key] = nil
         end
      elseif (verb == 'add' and
              path == '/softwire-config/binding-table/softwire') then
         local bt = native_config.softwire_config.binding_table
         for k,v in cltable.pairs(
            ietf_binding_table_from_native(
               { psid_map = bt.psid_map, softwire = data })) do
            for _,instance in cltable.pairs(br.br_instances.br_instance) do
               instance.binding_table.binding_entry[k] = v
            end
         end
      elseif (verb == 'set' and path == "/softwire-config/name") then
	 local br = cached_config.softwire_config.binding.br
	 for _, instance in cltable.pairs(br.br_instances.br_instance) do
	    instance.name = data
	 end
      else
         cached_config = nil
      end
   end
   return ret
end

function get_config_support()
   return {
      validate_config = function() end,
      validate_update = function() end,
      compute_config_actions = compute_config_actions,
      update_mutable_objects_embedded_in_app_initargs =
         update_mutable_objects_embedded_in_app_initargs,
      compute_apps_to_restart_after_configuration_update =
         compute_apps_to_restart_after_configuration_update,
      translators = { ['ietf-softwire'] = ietf_softwire_translator () }
   }
end
