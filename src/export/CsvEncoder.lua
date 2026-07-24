-- Deterministic RFC 4180-style CSV encoding with spreadsheet-injection guards.

FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Export = FieldProfitabilityLedger.Export or {}

local CsvEncoder = {}

local MAX_COLUMNS = 128
local MAX_ROWS = 1000000
local MAX_BYTES = 64 * 1024 * 1024
local CHUNK_BYTES = 32 * 1024

local function finiteNumber(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function decimalPoint()
    local sample = string.format("%.1f", 1.5)
    return string.sub(sample, 2, #sample - 1)
end

local function invariantNumber(value)
    if not finiteNumber(value) then return nil, "nonFiniteCsvNumber" end
    if value == 0 then return "0" end
    local result = string.format("%.17g", value)
    local point = decimalPoint()
    if point ~= "." and #point > 0 then
        result = string.gsub(result, point, ".", 1)
    end
    result = string.gsub(result, "E", "e")
    result = string.gsub(result, "e%+", "e")
    return result
end

local function guardedText(value)
    if #value > 0 then
        local first = string.sub(value, 1, 1)
        if first == "=" or first == "+" or first == "-" or first == "@"
            or first == "\t" or first == "\r" or first == "\n" then
            return "'" .. value
        end
    end
    return value
end

local function cell(value, protectFormula)
    if value == nil then return "" end
    local valueType = type(value)
    local text
    if valueType == "string" then
        text = protectFormula and guardedText(value) or value
    elseif valueType == "number" then
        local reason
        text, reason = invariantNumber(value)
        if text == nil then return nil, reason end
    elseif valueType == "boolean" then
        text = value and "true" or "false"
    else
        return nil, "unsupportedCsvValue"
    end
    if string.find(text, '[,"\r\n]') ~= nil then
        return '"' .. string.gsub(text, '"', '""') .. '"'
    end
    return text
end

local function normalizeColumns(columns)
    if type(columns) ~= "table" or getmetatable(columns) ~= nil
        or #columns == 0 or #columns > MAX_COLUMNS then
        return nil, "invalidCsvShape"
    end
    local normalized = {}
    local seen = {}
    for index, column in ipairs(columns) do
        if type(column) ~= "table" or getmetatable(column) ~= nil then
            return nil, "invalidCsvColumn"
        end
        for key in next, column do
            if key ~= "key" and key ~= "heading" then
                return nil, "invalidCsvColumn"
            end
        end
        local key = rawget(column, "key")
        local heading = rawget(column, "heading")
        if type(key) ~= "string" or #key == 0 or #key > 64 or seen[key]
            or type(heading) ~= "string" or #heading == 0 or #heading > 128 then
            return nil, "invalidCsvColumn"
        end
        seen[key] = true
        normalized[index] = {key = key, heading = heading}
    end
    return normalized
end

local function encodeRow(columns, row, headings)
    if not headings and (type(row) ~= "table" or getmetatable(row) ~= nil) then
        return nil, "invalidCsvRow"
    end
    local parts = {}
    for index, column in ipairs(columns) do
        if index > 1 then parts[#parts + 1] = "," end
        local value = headings and column.heading or rawget(row, column.key)
        local encoded, reason = cell(value, not headings)
        if encoded == nil then return nil, reason end
        parts[#parts + 1] = encoded
    end
    parts[#parts + 1] = "\r\n"
    return table.concat(parts)
end

function CsvEncoder.newStream(columns, sink, limits)
    local normalized, reason = normalizeColumns(columns)
    if normalized == nil then return nil, reason end
    if type(sink) ~= "function" then return nil, "invalidCsvSink" end
    limits = limits or {}
    if type(limits) ~= "table" or getmetatable(limits) ~= nil then
        return nil, "invalidCsvLimits"
    end
    local rowLimit = rawget(limits, "maxRows") or MAX_ROWS
    local byteLimit = rawget(limits, "maxBytes") or MAX_BYTES
    local chunkLimit = rawget(limits, "chunkBytes") or CHUNK_BYTES
    if not finiteNumber(rowLimit) or rowLimit ~= math.floor(rowLimit)
        or rowLimit < 0 or rowLimit > MAX_ROWS
        or not finiteNumber(byteLimit) or byteLimit ~= math.floor(byteLimit)
        or byteLimit < 1 or byteLimit > MAX_BYTES
        or not finiteNumber(chunkLimit) or chunkLimit ~= math.floor(chunkLimit)
        or chunkLimit < 1 or chunkLimit > CHUNK_BYTES then
        return nil, "invalidCsvLimits"
    end
    local stream = {rows=0, bytes=0, buffer="", finished=false,
        aborted=false, sink=sink, columns=normalized,
        rowLimit=rowLimit, byteLimit=byteLimit, chunkLimit=chunkLimit}
    local function emit(value)
        local offset = 1
        while offset <= #value do
            local room = stream.chunkLimit - #stream.buffer
            local count = math.min(room, #value - offset + 1)
            stream.buffer = stream.buffer .. string.sub(value, offset, offset + count - 1)
            offset = offset + count
            if #stream.buffer == stream.chunkLimit then
                local called, accepted, sinkReason = pcall(stream.sink, stream.buffer)
                if not called or accepted == nil or accepted == false then
                    return nil, type(sinkReason) == "string" and sinkReason
                        or "csvSinkFailed"
                end
                stream.buffer = ""
            end
        end
        return true
    end
    function stream:_append(value, dataRow)
        if self.finished or self.aborted then return nil, "csvStreamClosed" end
        local proposedRows = self.rows + (dataRow and 1 or 0)
        local proposedBytes = self.bytes + #value
        if proposedRows > self.rowLimit then return nil, "csvTooManyRows" end
        if proposedBytes > self.byteLimit then return nil, "csvTooLarge" end
        local ok, appendReason = emit(value)
        if not ok then self.aborted = true; return nil, appendReason end
        self.rows, self.bytes = proposedRows, proposedBytes
        return true
    end
    function stream:writeRow(row)
        local encoded, rowReason = encodeRow(self.columns, row, false)
        if encoded == nil then self.aborted = true; return nil, rowReason end
        return self:_append(encoded, true)
    end
    function stream:finish()
        if self.finished or self.aborted then return nil, "csvStreamClosed" end
        if #self.buffer > 0 then
            local called, accepted, sinkReason = pcall(self.sink, self.buffer)
            if not called or accepted == nil or accepted == false then
                self.aborted = true
                return nil, type(sinkReason) == "string" and sinkReason
                    or "csvSinkFailed"
            end
            self.buffer = ""
        end
        self.finished = true
        return {rows=self.rows, bytes=self.bytes}
    end
    function stream:abort()
        if self.finished then return nil, "csvStreamClosed" end
        self.aborted, self.buffer = true, ""
        return true
    end
    local heading = encodeRow(normalized, nil, true)
    local appended, appendReason = stream:_append(heading, false)
    if not appended then return nil, appendReason end
    return stream
end

function CsvEncoder.encode(columns, rows)
    if type(rows) ~= "table" or getmetatable(rows) ~= nil
        or #rows > MAX_ROWS then return nil, "invalidCsvShape" end
    local chunks = {}
    local stream, reason = CsvEncoder.newStream(columns, function(chunk)
        chunks[#chunks + 1] = chunk
        return true
    end)
    if stream == nil then return nil, reason end
    for _, row in ipairs(rows) do
        local ok
        ok, reason = stream:writeRow(row)
        if not ok then return nil, reason end
    end
    local finished
    finished, reason = stream:finish()
    if finished == nil then return nil, reason end
    return table.concat(chunks)
end

CsvEncoder.invariantNumber = invariantNumber
CsvEncoder.MAX_ROWS = MAX_ROWS
CsvEncoder.MAX_BYTES = MAX_BYTES
CsvEncoder.CHUNK_BYTES = CHUNK_BYTES
FieldProfitabilityLedger.Export.CsvEncoder = CsvEncoder
return CsvEncoder
