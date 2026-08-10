-- Pure Lua CMSIS-SVD parser.
--
-- The parser deliberately does not depend on an XML module.  parse() returns
-- a normalized, flattened model (or nil, error).  load_file() is synchronous
-- unless a callback is supplied; a callback receives (model, error).

local M = {}

local function local_name(name)
  return (name and name:match('([^:]+)$')) or name
end

local function trim(value)
  if value == nil then
    return nil
  end
  return (tostring(value):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function decode_entities(value)
  if not value or not value:find('&', 1, true) then
    return value
  end
  local entities = { amp = '&', lt = '<', gt = '>', quot = '"', apos = "'" }
  local function replacement(entity)
    local named = entities[entity]
    if named then
      return named
    end
    local number = entity:match('^#x([%da-fA-F]+)$')
    if not number then
      number = entity:match('^#([%d]+)$')
    end
    if not number then
      return '&' .. entity .. ';'
    end
    local code = tonumber(number, entity:sub(2, 2):lower() == 'x' and 16 or 10)
    if not code or code < 0 or code > 0x10ffff then
      return '&' .. entity .. ';'
    end
    -- utf8.char is not available in all Lua versions supported by Neovim.
    if code < 0x80 then
      return string.char(code)
    elseif code < 0x800 then
      return string.char(0xc0 + math.floor(code / 0x40), 0x80 + code % 0x40)
    elseif code < 0x10000 then
      return string.char(0xe0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
    end
    return string.char(
      0xf0 + math.floor(code / 0x40000),
      0x80 + math.floor(code / 0x1000) % 0x40,
      0x80 + math.floor(code / 0x40) % 0x40,
      0x80 + code % 0x40
    )
  end
  return (value:gsub('&([^;]+);', replacement))
end

local function tag_end(xml, start)
  local quote
  for i = start, #xml do
    local c = xml:sub(i, i)
    if quote then
      if c == quote then
        quote = nil
      end
    elseif c == "'" or c == '"' then
      quote = c
    elseif c == '>' then
      return i
    end
  end
end

local function parse_attributes(body, start)
  local attrs = {}
  local i = start
  while i <= #body do
    local s, e, name = body:find('^%s*([^%s=/>]+)', i)
    if not s then
      break
    end
    i = e + 1
    local equals = body:match('^%s*()=', i)
    if not equals then
      return nil, 'attribute ' .. tostring(name) .. ' has no value'
    end
    i = equals + 1
    local quote = body:sub(i, i)
    if quote ~= "'" and quote ~= '"' then
      return nil, 'attribute ' .. tostring(name) .. ' is not quoted'
    end
    local finish = body:find(quote, i + 1, true)
    if not finish then
      return nil, 'unterminated attribute ' .. tostring(name)
    end
    attrs[local_name(name)] = decode_entities(body:sub(i + 1, finish - 1))
    i = finish + 1
  end
  return attrs
end

-- Small XML tree reader. It handles the XML found in CMSIS-SVD files,
-- including comments, CDATA, namespaces, declarations, and quoted attrs.
local function xml_tree(xml)
  if type(xml) ~= 'string' then
    return nil, 'XML must be a string'
  end
  local root, stack, position = nil, {}, 1
  local function add_text(text)
    if #stack > 0 and text ~= '' then
      stack[#stack].text = (stack[#stack].text or '') .. decode_entities(text)
    end
  end
  while position <= #xml do
    local opening = xml:find('<', position, true)
    if not opening then
      add_text(xml:sub(position))
      break
    end
    add_text(xml:sub(position, opening - 1))
    if xml:sub(opening, opening + 3) == '<!--' then
      local finish = xml:find('-->', opening + 4, true)
      if not finish then
        return nil, 'unterminated XML comment'
      end
      position = finish + 3
    elseif xml:sub(opening, opening + 8) == '<![CDATA[' then
      local finish = xml:find(']]>', opening + 9, true)
      if not finish then
        return nil, 'unterminated CDATA section'
      end
      add_text(xml:sub(opening + 9, finish - 1))
      position = finish + 3
    elseif xml:sub(opening, opening + 1) == '<?' then
      local finish = xml:find('?>', opening + 2, true)
      if not finish then
        return nil, 'unterminated XML declaration'
      end
      position = finish + 2
    elseif xml:sub(opening, opening + 1) == '<!' then
      -- SVDs occasionally carry a DOCTYPE. Ignore it, including an internal
      -- subset, without mistaking its '>' characters for the end.
      local i, quote, brackets = opening + 2, nil, 0
      local finish
      while i <= #xml do
        local c = xml:sub(i, i)
        if quote then
          if c == quote then
            quote = nil
          end
        elseif c == "'" or c == '"' then
          quote = c
        elseif c == '[' then
          brackets = brackets + 1
        elseif c == ']' and brackets > 0 then
          brackets = brackets - 1
        elseif c == '>' and brackets == 0 then
          finish = i
          break
        end
        i = i + 1
      end
      if not finish then
        return nil, 'unterminated XML declaration or doctype'
      end
      position = finish + 1
    else
      local finish = tag_end(xml, opening + 1)
      if not finish then
        return nil, 'unterminated XML tag'
      end
      local body = xml:sub(opening + 1, finish - 1)
      if body:match('^%s*/') then
        local name = body:match('^%s*/%s*([^%s>]+)')
        local node = stack[#stack]
        if not node or local_name(node.tag) ~= local_name(name) then
          return nil, 'mismatched closing tag ' .. tostring(name)
        end
        stack[#stack] = nil
      else
        local self_closing = body:match('/%s*$') ~= nil
        if self_closing then
          body = body:gsub('/%s*$', '')
        end
        local name = body:match('^%s*([^%s/>]+)')
        if not name then
          return nil, 'tag without a name'
        end
        local name_end = body:find(name, 1, true) + #name
        local attrs, err = parse_attributes(body, name_end)
        if not attrs then
          return nil, err
        end
        local node = { tag = local_name(name), attrs = attrs, children = {}, text = '' }
        if #stack > 0 then
          table.insert(stack[#stack].children, node)
        elseif root then
          return nil, 'multiple XML root elements'
        else
          root = node
        end
        if not self_closing then
          table.insert(stack, node)
        end
      end
      position = finish + 1
    end
  end
  if #stack > 0 then
    return nil, 'unclosed XML tag ' .. tostring(stack[#stack].tag)
  end
  if not root then
    return nil, 'XML has no root element'
  end
  return root
end

local function child(node, name)
  if not node then
    return nil
  end
  name = local_name(name)
  for _, item in ipairs(node.children or {}) do
    if item.tag == name then
      return item
    end
  end
end

local function children(node, name)
  local result = {}
  if node then
    name = local_name(name)
    for _, item in ipairs(node.children or {}) do
      if item.tag == name then
        result[#result + 1] = item
      end
    end
  end
  return result
end

local function text(node, name)
  local item = child(node, name)
  return item and trim(item.text) or nil
end

local function number(value, default)
  value = trim(value)
  if not value or value == '' then
    return default
  end
  value = value:gsub('^#', ''):gsub('[_ ,]', '')
  local sign = 1
  if value:sub(1, 1) == '-' then
    sign, value = -1, value:sub(2)
  end
  local hex = value:match('^0[xX](.*)$')
  local result
  if hex then
    result = tonumber(hex, 16)
  else
    result = tonumber(value)
  end
  return result and sign * result or default
end

local function clone(node)
  if not node then
    return nil
  end
  local result = { tag = node.tag, attrs = {}, children = {}, text = node.text }
  for key, value in pairs(node.attrs or {}) do
    result.attrs[key] = value
  end
  for _, item in ipairs(node.children or {}) do
    result.children[#result.children + 1] = clone(item)
  end
  return result
end

local merge_containers = {
  registers = true,
  fields = true,
  peripherals = true,
  enumeratedValues = true,
  defaultRegisterProperties = true,
  registerProperties = true,
  addressBlock = true,
}

local function node_identity(node)
  if node.attrs and node.attrs.name then
    return node.attrs.name
  end
  if
    node.tag == 'register'
    or node.tag == 'cluster'
    or node.tag == 'field'
    or node.tag == 'peripheral'
    or node.tag == 'enumeratedValue'
  then
    return text(node, 'name')
  end
end

local function merge(base, overlay)
  local result = clone(base) or { tag = overlay.tag, attrs = {}, children = {}, text = '' }
  for key, value in pairs(overlay.attrs or {}) do
    result.attrs[key] = value
  end
  if trim(overlay.text) ~= '' then
    result.text = overlay.text
  end
  for _, incoming in ipairs(overlay.children or {}) do
    local match
    local incoming_id = node_identity(incoming)
    for index, existing in ipairs(result.children) do
      if existing.tag == incoming.tag then
        local existing_id = node_identity(existing)
        if incoming_id and existing_id and incoming_id == existing_id then
          match = index
          break
        elseif not incoming_id and not existing_id and merge_containers[incoming.tag] then
          match = index
          break
        elseif not incoming_id and not existing_id and incoming.tag ~= 'enumeratedValue' then
          match = index
          break
        end
      end
    end
    if match then
      result.children[match] = merge(result.children[match], incoming)
    else
      result.children[#result.children + 1] = clone(incoming)
    end
  end
  return result
end

local function reference_name(reference)
  reference = trim(reference)
  return reference and reference:match('([^%.]+)$') or reference
end

local function resolve(map, node, seen)
  if not node then
    return nil
  end
  local source = node.attrs and node.attrs.derivedFrom
  if not source then
    return clone(node)
  end
  seen = seen or {}
  local node_name = (node.attrs and node.attrs.name) or text(node, 'name')
  local key = (node_name and map[node_name]) or node_name or node
  if seen[key] then
    return clone(node)
  end
  seen[key] = true
  local source_node = map[source] or map[reference_name(source)]
  local result = source_node and resolve(map, source_node, seen)
    or { tag = node.tag, attrs = {}, children = {}, text = '' }
  seen[key] = nil
  return merge(result, node)
end

local function value(node, name, fallback)
  return text(node, name) or fallback
end

local function parse_index_list(value_text, count)
  value_text = trim(value_text)
  if not value_text or value_text == '' then
    local result = {}
    for i = 0, count - 1 do
      result[#result + 1] = tostring(i)
    end
    return result
  end
  local result = {}
  for part in value_text:gmatch('[^,%s]+') do
    local first, last = part:match('^([^%-]+)%-(.+)$')
    if first and last and tonumber(first) and tonumber(last) then
      local a, b = tonumber(first), tonumber(last)
      local step = a <= b and 1 or -1
      for i = a, b, step do
        result[#result + 1] = tostring(i)
      end
    elseif first and last and #first == 1 and #last == 1 then
      local a, b = first:byte(), last:byte()
      local step = a <= b and 1 or -1
      for i = a, b, step do
        result[#result + 1] = string.char(i)
      end
    else
      result[#result + 1] = part
    end
  end
  while #result < count do
    result[#result + 1] = tostring(#result)
  end
  return result
end

local function substitutions(node, callback)
  local count = number(text(node, 'dim'), 1)
  if count < 1 then
    count = 1
  end
  local increment = number(text(node, 'dimIncrement'), 0)
  local indexes = parse_index_list(text(node, 'dimIndex'), count)
  for i = 1, count do
    local item = clone(node)
    local index = indexes[i]
    local function replace(value_text)
      if not value_text then
        return value_text
      end
      return value_text:gsub('%%[sd]', index)
    end
    item.attrs.name = replace(item.attrs.name)
    item.text = replace(item.text)
    local item_name = child(item, 'name')
    if item_name then
      item_name.text = replace(item_name.text)
    end
    local item_display = child(item, 'displayName')
    if item_display then
      item_display.text = replace(item_display.text)
    end
    callback(item, index, i - 1, increment)
  end
end

local function properties(node, inherited)
  local result = {}
  for key, val in pairs(inherited or {}) do
    result[key] = val
  end
  local source = child(node, 'registerProperties') or child(node, 'defaultRegisterProperties')
  if source then
    for _, key in ipairs({ 'size', 'access', 'resetValue', 'resetMask' }) do
      local raw = text(source, key)
      if raw ~= nil then
        result[key] = (key == 'access' and raw) or number(raw)
      end
    end
  end
  for _, key in ipairs({ 'size', 'access', 'resetValue', 'resetMask' }) do
    local raw = text(node, key)
    if raw ~= nil then
      result[key] = (key == 'access' and raw) or number(raw)
    end
  end
  return result
end

local function resolve_field(node, field_map, register_name)
  local source = node and node.attrs and node.attrs.derivedFrom
  if source and field_map then
    local candidates = {
      register_name and (register_name .. '.' .. source) or nil,
      register_name and (register_name .. '.' .. reference_name(source)) or nil,
      source,
      reference_name(source),
    }
    for _, key in ipairs(candidates) do
      if key and field_map[key] then
        return merge(field_map[key], node)
      end
    end
  end
  return resolve(field_map or {}, node)
end

local function field_model(node, inherited_access, field_map, register_name)
  local effective = resolve_field(node, field_map, register_name)
  local result = {
    name = value(effective, 'name', effective.attrs.name),
    displayName = value(effective, 'displayName'),
    description = value(effective, 'description'),
    access = value(effective, 'access', inherited_access),
    resetValue = number(text(effective, 'resetValue')),
    derivedFrom = effective.attrs.derivedFrom,
  }
  local bit_offset = number(text(effective, 'bitOffset'))
  local bit_width = number(text(effective, 'bitWidth'))
  if bit_offset == nil or bit_width == nil then
    local lsb, msb = number(text(effective, 'lsb')), number(text(effective, 'msb'))
    if lsb ~= nil and msb ~= nil then
      bit_offset, bit_width = lsb, msb - lsb + 1
    end
  end
  if bit_offset == nil or bit_width == nil then
    local range = text(effective, 'bitRange')
    local msb, lsb = range and range:match('^%[%s*(%d+)%s*:%s*(%d+)%s*%]$')
    if msb and lsb then
      bit_offset, bit_width = tonumber(lsb), tonumber(msb) - tonumber(lsb) + 1
    end
  end
  result.bitOffset, result.bitWidth = bit_offset, bit_width
  result.lsb = bit_offset
  result.msb = bit_offset and bit_width and bit_offset + bit_width - 1 or nil
  result.enumeratedValues = {}
  for _, enum_group in ipairs(children(effective, 'enumeratedValues')) do
    for _, enum in ipairs(children(enum_group, 'enumeratedValue')) do
      result.enumeratedValues[#result.enumeratedValues + 1] = {
        name = value(enum, 'name', enum.attrs.name),
        value = number(text(enum, 'value')),
        description = value(enum, 'description'),
        usage = value(enum, 'usage'),
      }
    end
  end
  result.enumeratedValuesByName = {}
  for _, enum in ipairs(result.enumeratedValues) do
    if enum.name then
      result.enumeratedValuesByName[enum.name] = enum
    end
  end
  return result
end

local function make_register(effective, peripheral, offset, cluster, dim_index, field_map)
  local result = {
    name = value(effective, 'name', effective.attrs.name),
    displayName = value(effective, 'displayName'),
    description = value(effective, 'description'),
    addressOffset = offset,
    address = peripheral.baseAddress + offset * (peripheral.addressUnitScale or 1),
    size = number(text(effective, 'size'), peripheral._properties.size),
    access = value(effective, 'access', peripheral._properties.access),
    readAction = value(effective, 'readAction'),
    resetValue = number(text(effective, 'resetValue'), peripheral._properties.resetValue),
    resetMask = number(text(effective, 'resetMask'), peripheral._properties.resetMask),
    derivedFrom = effective.attrs.derivedFrom,
    dim = number(text(effective, 'dim')),
    dimIncrement = number(text(effective, 'dimIncrement')),
    dimIndex = dim_index,
    cluster = cluster,
    fields = {},
  }
  result.fields_by_name = {}
  for _, field in ipairs(children(child(effective, 'fields'), 'field')) do
    substitutions(field, function(item)
      local normalized = field_model(item, result.access, field_map, value(effective, 'name', effective.attrs.name))
      result.fields[#result.fields + 1] = normalized
      if normalized.name then
        result.fields_by_name[normalized.name] = normalized
      end
    end)
  end
  return result
end

local function build_model(root)
  local defaults = {}
  local defaults_node = child(root, 'defaultRegisterProperties')
  for _, key in ipairs({ 'size', 'access', 'resetValue', 'resetMask' }) do
    local raw = text(defaults_node, key) or text(root, key)
    if raw ~= nil then
      defaults[key] = key == 'access' and raw or number(raw)
    end
  end

  local peripheral_nodes = children(child(root, 'peripherals'), 'peripheral')
  local peripheral_map = {}
  for _, node in ipairs(peripheral_nodes) do
    local name = value(node, 'name', node.attrs.name)
    if name then
      peripheral_map[name] = node
    end
  end
  local effective_peripherals = {}
  for _, node in ipairs(peripheral_nodes) do
    local name = value(node, 'name', node.attrs.name)
    effective_peripherals[name] = resolve(peripheral_map, node)
  end

  local model = {
    name = value(root, 'name'),
    displayName = value(root, 'displayName'),
    description = value(root, 'description'),
    vendor = value(root, 'vendor'),
    vendorId = value(root, 'vendorId'),
    version = value(root, 'version'),
    licenseText = value(root, 'licenseText'),
    addressUnitBits = number(text(root, 'addressUnitBits')),
    width = number(text(root, 'width')),
    defaults = defaults,
    cpu = {},
    peripherals = {},
    peripherals_by_name = {},
  }
  local cpu = child(root, 'cpu')
  if cpu then
    for _, key in ipairs({
      'name',
      'revision',
      'endian',
      'mpuPresent',
      'fpuPresent',
      'fpuDP',
      'dspPresent',
      'icachePresent',
      'dcachePresent',
      'vtorPresent',
      'nvicPrioBits',
      'vendorSystickConfig',
    }) do
      local raw = text(cpu, key)
      if raw ~= nil then
        model.cpu[key] = tonumber(raw) or raw
      end
    end
  end

  local address_unit_bits = model.addressUnitBits or 8
  local address_unit_scale = address_unit_bits / 8
  if address_unit_scale <= 0 then
    address_unit_scale = 1
  end
  for _, original in ipairs(peripheral_nodes) do
    local name = value(original, 'name', original.attrs.name)
    local node = effective_peripherals[name]
    local base_raw = number(text(node, 'baseAddress'), 0)
    local peripheral = {
      name = name,
      displayName = value(node, 'displayName'),
      description = value(node, 'description'),
      groupName = value(node, 'groupName'),
      baseAddress = base_raw * address_unit_scale,
      baseAddressRaw = base_raw,
      addressUnitBits = address_unit_bits,
      addressUnitScale = address_unit_scale,
      derivedFrom = node.attrs.derivedFrom,
      registers = {},
      registers_by_name = {},
      _properties = properties(node, defaults),
    }
    peripheral.size = peripheral._properties.size
    peripheral.access = peripheral._properties.access
    peripheral.resetValue = peripheral._properties.resetValue
    peripheral.resetMask = peripheral._properties.resetMask
    local block = child(node, 'addressBlock')
    if block then
      peripheral.addressBlock = {
        offset = number(text(block, 'offset'), 0),
        size = number(text(block, 'size')),
        usage = value(block, 'usage'),
        protection = value(block, 'protection'),
      }
    end

    local register_container = child(node, 'registers')
    local register_nodes = register_container and register_container.children or {}
    local register_map, field_map = {}, {}

    -- Index registers, clusters, and fields recursively. Qualified keys are
    -- needed for legal derivedFrom="OTHER_CLUSTER.REG" references; the old
    -- flat register-only map silently lost derived clusters.
    local function index_items(items, path_prefix, peripheral_prefix, local_names)
      for _, item in ipairs(items or {}) do
        if item.tag == 'register' or item.tag == 'cluster' then
          local item_name = value(item, 'name', item.attrs.name)
          if item_name then
            local full_name = path_prefix and (path_prefix .. '.' .. item_name) or item_name
            local qualified = peripheral_prefix and (peripheral_prefix .. '.' .. full_name) or full_name
            register_map[qualified] = item
            if local_names then
              register_map[full_name] = item
              register_map[item_name] = item
            end
            if item.tag == 'register' then
              for _, field in ipairs(children(child(item, 'fields'), 'field')) do
                local field_name = value(field, 'name', field.attrs.name)
                if field_name then
                  field_map[qualified .. '.' .. field_name] = field
                  if local_names then
                    field_map[full_name .. '.' .. field_name] = field
                    if not field_map[field_name] then
                      field_map[field_name] = field
                    end
                  end
                end
              end
            else
              local nested = child(item, 'registers')
              index_items(nested and nested.children, full_name, peripheral_prefix, local_names)
            end
          end
        end
      end
    end

    index_items(register_nodes, nil, nil, true)
    -- A global fallback handles common PERIPHERAL.REGISTER and
    -- PERIPHERAL.CLUSTER.REGISTER derivedFrom references.
    for _, other in ipairs(peripheral_nodes) do
      local other_name = value(other, 'name', other.attrs.name)
      local other_node = effective_peripherals[other_name]
      local other_regs = child(other_node, 'registers')
      index_items(other_regs and other_regs.children, nil, other_name, false)
    end

    local function walk(container, base_offset, cluster_name)
      for _, raw_item in ipairs(container or {}) do
        if raw_item.tag == 'register' then
          local effective = resolve(register_map, raw_item)
          substitutions(effective, function(item, index, zero_index, increment)
            local item_name = value(item, 'name', item.attrs.name)
            local full_name = cluster_name and (cluster_name .. '.' .. item_name) or item_name
            local offset = base_offset + number(text(item, 'addressOffset'), 0) + zero_index * increment
            local normalized = make_register(item, peripheral, offset, cluster_name, index, field_map)
            normalized.name = full_name
            peripheral.registers[#peripheral.registers + 1] = normalized
            peripheral.registers_by_name[full_name] = normalized
            -- Also expose the unqualified name when it is unambiguous.
            if not peripheral.registers_by_name[item_name] then
              peripheral.registers_by_name[item_name] = normalized
            end
          end)
        elseif raw_item.tag == 'cluster' then
          local cluster = resolve(register_map, raw_item)
          substitutions(cluster, function(item, index, zero_index, increment)
            local item_name = value(item, 'name', item.attrs.name)
            local path = cluster_name and (cluster_name .. '.' .. item_name) or item_name
            local offset = base_offset + number(text(item, 'addressOffset'), 0) + zero_index * increment
            local nested = child(item, 'registers')
            walk(nested and nested.children, offset, path)
          end)
        end
      end
    end
    walk(register_nodes, 0, nil)
    peripheral._properties = nil
    model.peripherals[#model.peripherals + 1] = peripheral
    model.peripherals_by_name[name] = peripheral
  end
  -- Common singular aliases make interactive consumers less verbose.
  model.peripheral_by_name = model.peripherals_by_name
  return model
end

function M.parse(xml)
  local root, err = xml_tree(xml)
  if not root then
    return nil, err
  end
  if root.tag ~= 'device' then
    return nil, 'SVD root must be <device>'
  end
  return build_model(root)
end

function M.load_file(path, callback)
  local file, err = io.open(path, 'rb')
  if not file then
    if callback then
      callback(nil, err)
    end
    return nil, err
  end
  local xml = file:read('*a')
  file:close()
  local model, parse_err = M.parse(xml)
  if callback then
    callback(model, parse_err)
  end
  return model, parse_err
end

M.load = M.load_file
M.parse_file = M.load_file

return M
