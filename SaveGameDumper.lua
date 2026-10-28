SaveGameDumper = SaveGameDumper or {}

local MAX_DEPTH = 32

local function utf8_valid(str)
    local i, len = 1, #str
    while i <= len do
        local b = str:byte(i)
        local n = b < 0x80 and 0 or (b >= 0xC2 and b < 0xE0) and 1 or (b >= 0xE0 and b < 0xF0) and 2 or (b >= 0xF0 and b < 0xF5) and 3 or nil
        if not n or i + n > len then
            return false
        end
        for j = 1, n do
            local c = str:byte(i + j)
            if c < 0x80 or c > 0xBF then
                return false
            end
        end
        i = i + n + 1
    end
    return true
end

-- no control characters and valid UTF-8
local function is_text(str)
    if str:find("[%c]") then
        return false
    end
    return str:find("[\128-\255]") == nil or utf8_valid(str)
end

-- writes value as indented JSON into buffer; unsupported types become strings, cycles and too deep tables become null
local function write_value(buffer, value, indent, seen, depth)
    local vtype = type(value)

    if vtype == "string" then
        if not is_text(value) then
            -- binary strings are values stored via Application:digest_value(x, true)
            local ok, decoded = blt.pcall(Application.digest_value, Application, value, false)
            if ok and type(decoded) == "number" then
                return write_value(buffer, decoded, indent, seen, depth)
            end
            value = "hex:" .. value:gsub(".", function(c)
                return string.format("%02x", c:byte())
            end)
        end
        local escaped = value:gsub('[%c"\\]', function(c)
            return string.format("\\u%04x", c:byte())
        end)
        table.insert(buffer, '"' .. escaped .. '"')
    elseif vtype == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            table.insert(buffer, "null")
        else
            table.insert(buffer, string.format("%.14g", value))
        end
    elseif vtype == "boolean" then
        table.insert(buffer, tostring(value))
    elseif vtype == "table" then
        if seen[value] or depth > MAX_DEPTH then
            table.insert(buffer, "null")
            return
        end
        seen[value] = true

        local count, max_index = 0, 0
        for k in pairs(value) do
            count = count + 1
            if type(k) == "number" and k > 0 and k == math.floor(k) and k > max_index then
                max_index = k
            end
        end

        local inner = indent .. "  "
        if count == 0 then
            table.insert(buffer, "[]")
        elseif count == max_index then
            table.insert(buffer, "[\n")
            for i = 1, max_index do
                table.insert(buffer, inner)
                write_value(buffer, value[i], inner, seen, depth + 1)
                table.insert(buffer, i < max_index and ",\n" or "\n")
            end
            table.insert(buffer, indent .. "]")
        else
            local keys = {}
            for k in pairs(value) do
                table.insert(keys, k)
            end
            table.sort(keys, function(a, b)
                return tostring(a) < tostring(b)
            end)
            table.insert(buffer, "{\n")
            for i, k in ipairs(keys) do
                table.insert(buffer, inner)
                write_value(buffer, tostring(k), inner, seen, depth + 1)
                table.insert(buffer, ": ")
                write_value(buffer, value[k], inner, seen, depth + 1)
                table.insert(buffer, i < #keys and ",\n" or "\n")
            end
            table.insert(buffer, indent .. "}")
        end

        seen[value] = nil
    elseif vtype == "nil" then
        table.insert(buffer, "null")
    else
        write_value(buffer, tostring(value), indent, seen, depth)
    end
end

---@param slot number
---@param cache table
function SaveGameDumper.dump(slot, cache)
    local name = slot == SavefileManager.SETTING_SLOT and "profile" or ("slot_" .. tostring(slot))
    local path = SavePath .. "SaveGameDumper_" .. name .. ".json"

    local buffer = {}
    write_value(buffer, cache, "", {}, 0)

    local file = io.open(path, "w+")
    if not file then
        log("[SaveGameDumper] Could not open " .. path)
        return
    end
    file:write(table.concat(buffer))
    file:close()
    log("[SaveGameDumper] Dumped " .. name .. " to " .. path)
end

Hooks:PostHook(SavefileManager, "_load_cache", "SaveGameDumper._load_cache", function(self, slot)
    local meta_data = self:_meta_data(slot)
    local cache = meta_data and meta_data.cache

    if cache then
        local ok, err = blt.pcall(SaveGameDumper.dump, slot, cache)
        if not ok then
            log("[SaveGameDumper] Dump failed: " .. tostring(err))
        end
    end
end)
