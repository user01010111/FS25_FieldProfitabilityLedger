FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Core = FieldProfitabilityLedger.Core or {}

local Validation = {}

local function isFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function isIntegerValue(value)
    return isFiniteNumber(value) and value == math.floor(value)
end

local function validateMaximum(value, reason)
    if not isIntegerValue(value) or value < 0 then
        return nil, reason
    end
    return value
end

function Validation.isFinite(value)
    return isFiniteNumber(value)
end

function Validation.number(value, minimum, maximum)
    if minimum ~= nil and not isFiniteNumber(minimum) then
        return nil, "invalidMinimum"
    end
    if maximum ~= nil and not isFiniteNumber(maximum) then
        return nil, "invalidMaximum"
    end
    if minimum ~= nil and maximum ~= nil and minimum > maximum then
        return nil, "invalidRange"
    end
    if type(value) ~= "number" then
        return nil, "expectedNumber"
    end
    if not isFiniteNumber(value) then
        return nil, "notFinite"
    end
    if minimum ~= nil and value < minimum then
        return nil, "belowMinimum"
    end
    if maximum ~= nil and value > maximum then
        return nil, "aboveMaximum"
    end
    return value
end

function Validation.integer(value, minimum, maximum)
    local accepted, reason = Validation.number(value, minimum, maximum)
    if accepted == nil then
        return nil, reason
    end
    if accepted ~= math.floor(accepted) then
        return nil, "expectedInteger"
    end
    return accepted
end

function Validation.enum(value, allowed)
    if type(allowed) ~= "table" or getmetatable(allowed) ~= nil then
        return nil, "invalidAllowed"
    end
    if value == nil or (type(value) == "number" and value ~= value) then
        return nil, "notAllowed"
    end
    if rawget(allowed, value) ~= true then
        return nil, "notAllowed"
    end
    return value
end

function Validation.asciiToken(value, maximumBytes)
    local acceptedMaximum, reason = validateMaximum(maximumBytes, "invalidMaximumBytes")
    if acceptedMaximum == nil then
        return nil, reason
    end
    if type(value) ~= "string" then
        return nil, "expectedString"
    end
    if #value == 0 then
        return nil, "emptyToken"
    end
    if #value > acceptedMaximum then
        return nil, "stringTooLong"
    end

    for index = 1, #value do
        local byte = string.byte(value, index)
        if byte < 33 or byte > 126 then
            return nil, "invalidAscii"
        end
    end

    return value
end

local function validateUtf8(value)
    local index = 1
    local length = #value

    while index <= length do
        local first = string.byte(value, index)
        local codePoint
        local width

        if first <= 0x7F then
            codePoint = first
            width = 1
        elseif first >= 0xC2 and first <= 0xDF then
            local second = string.byte(value, index + 1)
            if second == nil or second < 0x80 or second > 0xBF then
                return nil, "invalidUtf8"
            end
            codePoint = (first - 0xC0) * 0x40 + (second - 0x80)
            width = 2
        elseif first >= 0xE0 and first <= 0xEF then
            local second = string.byte(value, index + 1)
            local third = string.byte(value, index + 2)
            if second == nil or third == nil
                or second < 0x80 or second > 0xBF
                or third < 0x80 or third > 0xBF then
                return nil, "invalidUtf8"
            end
            if first == 0xE0 and second < 0xA0 then
                return nil, "invalidUtf8"
            end
            if first == 0xED and second > 0x9F then
                return nil, "invalidUtf8"
            end
            codePoint = (first - 0xE0) * 0x1000
                + (second - 0x80) * 0x40
                + (third - 0x80)
            width = 3
        elseif first >= 0xF0 and first <= 0xF4 then
            local second = string.byte(value, index + 1)
            local third = string.byte(value, index + 2)
            local fourth = string.byte(value, index + 3)
            if second == nil or third == nil or fourth == nil
                or second < 0x80 or second > 0xBF
                or third < 0x80 or third > 0xBF
                or fourth < 0x80 or fourth > 0xBF then
                return nil, "invalidUtf8"
            end
            if first == 0xF0 and second < 0x90 then
                return nil, "invalidUtf8"
            end
            if first == 0xF4 and second > 0x8F then
                return nil, "invalidUtf8"
            end
            codePoint = (first - 0xF0) * 0x40000
                + (second - 0x80) * 0x1000
                + (third - 0x80) * 0x40
                + (fourth - 0x80)
            width = 4
        else
            return nil, "invalidUtf8"
        end

        if codePoint < 0x20
            or (codePoint >= 0x7F and codePoint <= 0x9F) then
            return nil, "controlCharacter"
        end

        index = index + width
    end

    return true
end

function Validation.text(value, maximumBytes)
    local acceptedMaximum, reason = validateMaximum(maximumBytes, "invalidMaximumBytes")
    if acceptedMaximum == nil then
        return nil, reason
    end
    if type(value) ~= "string" then
        return nil, "expectedString"
    end
    if #value > acceptedMaximum then
        return nil, "stringTooLong"
    end

    local valid, utf8Reason = validateUtf8(value)
    if not valid then
        return nil, utf8Reason
    end

    return value
end

function Validation.array(value, maximumItems)
    local acceptedMaximum, reason = validateMaximum(maximumItems, "invalidMaximumItems")
    if acceptedMaximum == nil then
        return nil, reason
    end
    if type(value) ~= "table" then
        return nil, "expectedArray"
    end
    if getmetatable(value) ~= nil then
        return nil, "metatableNotAllowed"
    end

    local count = 0
    local maximumIndex = 0
    local hasInvalidIndex = false
    for key in pairs(value) do
        count = count + 1
        if count > acceptedMaximum then
            return nil, "tooManyItems"
        end
        if not isIntegerValue(key) or key < 1 then
            hasInvalidIndex = true
        elseif key > maximumIndex then
            maximumIndex = key
        end
    end

    if hasInvalidIndex then
        return nil, "invalidArrayIndex"
    end
    if maximumIndex ~= count then
        return nil, "sparseArray"
    end

    return value
end

local function readCopyLimits(limits)
    if type(limits) ~= "table" or getmetatable(limits) ~= nil then
        return nil, "invalidLimits"
    end

    local maxDepth = rawget(limits, "maxDepth")
    if not isIntegerValue(maxDepth) or maxDepth < 0 then
        return nil, "invalidMaxDepth"
    end

    local maxItems = rawget(limits, "maxItems")
    if not isIntegerValue(maxItems) or maxItems < 1 then
        return nil, "invalidMaxItems"
    end

    local maxStringBytes = rawget(limits, "maxStringBytes")
    if not isIntegerValue(maxStringBytes) or maxStringBytes < 0 then
        return nil, "invalidMaxStringBytes"
    end

    local maxNumber = rawget(limits, "maxNumber")
    if not isFiniteNumber(maxNumber) or maxNumber < 0 then
        return nil, "invalidMaxNumber"
    end
    if rawget(limits, "minNumber") ~= nil then
        return nil, "invalidLimits"
    end

    return {
        maxDepth = maxDepth,
        maxItems = maxItems,
        maxStringBytes = maxStringBytes,
        maxNumber = maxNumber
    }
end

local function unsignedByteLess(left, right)
    local sharedLength = math.min(#left, #right)
    for index = 1, sharedLength do
        local leftByte = string.byte(left, index)
        local rightByte = string.byte(right, index)
        if leftByte ~= rightByte then
            return leftByte < rightByte
        end
    end
    return #left < #right
end

local function classifyTable(value, maxStringBytes, maximumChildren)
    local numericCount = 0
    local childCount = 0
    local maximumIndex = 0
    local stringKeys = {}
    local hasNumeric = false
    local hasString = false
    local hasInvalidArrayIndex = false
    local hasInvalidKeyType = false
    local hasOverlongStringKey = false

    for key in pairs(value) do
        childCount = childCount + 1
        if childCount > maximumChildren then
            return nil, "maxItemsExceeded"
        end

        local keyType = type(key)
        if keyType == "number" then
            if not isIntegerValue(key) or key < 1 then
                hasInvalidArrayIndex = true
            else
                hasNumeric = true
                numericCount = numericCount + 1
                if key > maximumIndex then
                    maximumIndex = key
                end
            end
        elseif keyType == "string" then
            hasString = true
            if #key > maxStringBytes then
                hasOverlongStringKey = true
            end
            stringKeys[#stringKeys + 1] = key
        else
            hasInvalidKeyType = true
        end
    end

    if hasInvalidKeyType then
        return nil, "invalidKeyType"
    end
    if hasInvalidArrayIndex then
        return nil, "invalidArrayIndex"
    end
    if hasNumeric and hasString then
        return nil, "mixedTable"
    end
    if hasNumeric then
        if maximumIndex ~= numericCount then
            return nil, "sparseArray"
        end
        return {
            kind = "array",
            length = numericCount,
            childCount = childCount
        }
    end

    if hasOverlongStringKey then
        return nil, "maxStringBytesExceeded"
    end
    table.sort(stringKeys, unsignedByteLess)
    return {
        kind = "map",
        keys = stringKeys,
        childCount = childCount
    }
end

function Validation.copy(value, limits)
    local acceptedLimits, reason = readCopyLimits(limits)
    if acceptedLimits == nil then
        return nil, reason
    end

    local wrapper = {}
    local tasks = {
        {
            source = value,
            parent = wrapper,
            key = "value",
            depth = 0
        }
    }
    local seen = {}
    -- Count a node when it is discovered/queued, not when it is later popped.
    -- This reserves the complete pending frontier and prevents a nested table
    -- from enqueueing children against budget already consumed by siblings.
    local reservedItems = 1

    while #tasks > 0 do
        local task = tasks[#tasks]
        tasks[#tasks] = nil

        if task.depth > acceptedLimits.maxDepth then
            return nil, "maxDepthExceeded"
        end

        local source = task.source
        local sourceType = type(source)

        if sourceType == "nil" then
            rawset(task.parent, task.key, nil)
        elseif sourceType == "boolean" then
            rawset(task.parent, task.key, source)
        elseif sourceType == "number" then
            if not isFiniteNumber(source) then
                return nil, "notFinite"
            end
            if source < -acceptedLimits.maxNumber then
                return nil, "belowMinimum"
            end
            if source > acceptedLimits.maxNumber then
                return nil, "aboveMaximum"
            end
            rawset(task.parent, task.key, source)
        elseif sourceType == "string" then
            if #source > acceptedLimits.maxStringBytes then
                return nil, "maxStringBytesExceeded"
            end
            rawset(task.parent, task.key, source)
        elseif sourceType == "table" then
            if getmetatable(source) ~= nil then
                return nil, "metatableNotAllowed"
            end
            if seen[source] then
                return nil, "referenceReused"
            end

            if task.depth >= acceptedLimits.maxDepth and next(source) ~= nil then
                return nil, "maxDepthExceeded"
            end

            local remainingItems = acceptedLimits.maxItems - reservedItems
            local shape, shapeReason = classifyTable(
                source,
                acceptedLimits.maxStringBytes,
                remainingItems
            )
            if shape == nil then
                return nil, shapeReason
            end

            reservedItems = reservedItems + shape.childCount

            seen[source] = true
            local target = {}
            rawset(task.parent, task.key, target)

            if shape.kind == "array" then
                for index = shape.length, 1, -1 do
                    tasks[#tasks + 1] = {
                        source = rawget(source, index),
                        parent = target,
                        key = index,
                        depth = task.depth + 1
                    }
                end
            else
                for index = #shape.keys, 1, -1 do
                    local key = shape.keys[index]
                    tasks[#tasks + 1] = {
                        source = rawget(source, key),
                        parent = target,
                        key = key,
                        depth = task.depth + 1
                    }
                end
            end
        else
            return nil, "unsupportedType"
        end
    end

    return wrapper.value
end

FieldProfitabilityLedger.Core.Validation = Validation

return Validation
