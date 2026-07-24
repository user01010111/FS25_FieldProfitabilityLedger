-- Fixed-name savegame-local byte port for LedgerStore. The mission lifecycle
-- supplies the trusted savegame directory; callers cannot choose filenames.

FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Persistence = FieldProfitabilityLedger.Persistence or {}

local SavegameFilePort = {}

local CURRENT_NAME = "fieldProfitabilityLedger.xml"
local CANDIDATE_NAME = "fieldProfitabilityLedger.candidate.xml"
local BACKUP_NAME = "fieldProfitabilityLedger.previous.xml"
local MAX_BYTES = 32 * 1024 * 1024
local XML_ROOT = "fieldProfitabilityLedger"
local XML_CHUNK_BYTES = 32 * 1024
local MAX_XML_CHUNKS = math.ceil(MAX_BYTES / XML_CHUNK_BYTES) + 1

local function validDirectory(value)
    if type(value) ~= "string" or #value == 0 or #value > 4096
        or value:find("[%z\1-\31\127]") ~= nil then
        return false
    end
    local normalized = value:gsub("\\", "/")
    for segment in normalized:gmatch("[^/]+") do
        if segment == "." or segment == ".." then return false end
    end
    return true
end

local function join(directory, name)
    local final = directory:sub(-1)
    if final == "/" or final == "\\" then return directory .. name end
    return directory .. "/" .. name
end

local function defaultSystem(current, candidate, backup)
    local xmlClass = _G.XMLFile
    local exists = _G.fileExists
    local copy = _G.copyFile
    if type(xmlClass) ~= "table" or type(xmlClass.create) ~= "function"
        or type(xmlClass.load) ~= "function" or type(exists) ~= "function"
        or type(copy) ~= "function" then
        return nil
    end
    local candidateBytes = nil

    local function closeXml(xml)
        if type(xml) == "table" and type(xml.delete) == "function" then
            pcall(xml.delete, xml)
        end
    end

    local function splitUtf8(bytes)
        local chunks = {}
        local first = 1
        while first <= #bytes do
            local last = math.min(#bytes, first + XML_CHUNK_BYTES - 1)
            while last >= first and last < #bytes do
                local nextByte = string.byte(bytes, last + 1)
                if nextByte == nil or nextByte < 128 or nextByte > 191 then break end
                last = last - 1
            end
            if last < first then return nil end
            chunks[#chunks + 1] = string.sub(bytes, first, last)
            first = last + 1
        end
        return chunks
    end

    local function readXml(path, maximum)
        local existsOk, present = pcall(exists, path)
        if not existsOk then return nil, "fileExistsFailed" end
        if present ~= true then return nil, "notFound" end
        local loadOk, xml = pcall(xmlClass.load, "fplLedgerRead", path)
        if not loadOk or type(xml) ~= "table"
            or type(xml.getString) ~= "function" then
            closeXml(xml)
            return nil, "xmlLoadFailed"
        end
        local metadataOk, rawBytes = pcall(
            xml.getString, xml, XML_ROOT .. "#bytes")
        local chunksOk, rawChunks = pcall(
            xml.getString, xml, XML_ROOT .. "#chunks")
        local byteCount = metadataOk and tonumber(rawBytes) or nil
        local chunkCount = chunksOk and tonumber(rawChunks) or nil
        if type(byteCount) ~= "number" or byteCount ~= math.floor(byteCount)
            or byteCount <= 0 or byteCount > maximum
            or type(chunkCount) ~= "number" or chunkCount ~= math.floor(chunkCount)
            or chunkCount <= 0 or chunkCount > MAX_XML_CHUNKS
            or tostring(byteCount) ~= rawBytes or tostring(chunkCount) ~= rawChunks then
            closeXml(xml)
            return nil, "invalidXmlMetadata"
        end
        local chunks = {}
        local observedBytes = 0
        for index = 0, chunkCount - 1 do
            local ok, value = pcall(xml.getString, xml,
                string.format("%s.chunk(%d)#data", XML_ROOT, index))
            if not ok or type(value) ~= "string" or #value == 0 then
                closeXml(xml)
                return nil, "invalidXmlChunk"
            end
            observedBytes = observedBytes + #value
            if observedBytes > byteCount or observedBytes > maximum then
                closeXml(xml)
                return nil, "tooLarge"
            end
            chunks[#chunks + 1] = value
        end
        closeXml(xml)
        if observedBytes ~= byteCount then return nil, "xmlLengthMismatch" end
        return table.concat(chunks)
    end

    local function writeXml(path, bytes)
        local chunks = splitUtf8(bytes)
        if chunks == nil or #chunks == 0 or #chunks > MAX_XML_CHUNKS then
            return nil, "invalidXmlPayload"
        end
        local createOk, xml = pcall(
            xmlClass.create, "fplLedgerWrite", path, XML_ROOT)
        if not createOk or type(xml) ~= "table"
            or type(xml.setString) ~= "function" or type(xml.save) ~= "function" then
            closeXml(xml)
            return nil, "xmlCreateFailed"
        end
        local ok = pcall(xml.setString, xml, XML_ROOT .. "#bytes", tostring(#bytes))
        ok = ok and pcall(
            xml.setString, xml, XML_ROOT .. "#chunks", tostring(#chunks))
        for index = 1, #chunks do
            ok = ok and pcall(xml.setString, xml,
                string.format("%s.chunk(%d)#data", XML_ROOT, index - 1), chunks[index])
        end
        local saveOk, saved = false, nil
        if ok then saveOk, saved = pcall(xml.save, xml) end
        closeXml(xml)
        local existsOk, present = pcall(exists, path)
        if not ok or not saveOk or saved == false or not existsOk or present ~= true then
            return nil, "xmlSaveFailed"
        end
        return true
    end

    return {
        read = function(path, maximum)
            if path == candidate then
                if candidateBytes == nil then return nil, "notFound" end
                if #candidateBytes > maximum then return nil, "tooLarge" end
                return candidateBytes
            end
            if path ~= current and path ~= backup then return nil, "invalidPath" end
            return readXml(path, maximum)
        end,
        write = function(path, bytes)
            if path ~= candidate then return nil, "invalidPath" end
            candidateBytes = bytes
            return true
        end,
        rename = function(source, target)
            if source == candidate and target == current then
                if candidateBytes == nil then return nil, "notFound" end
                local written, reason = writeXml(current, candidateBytes)
                if written == true then candidateBytes = nil end
                return written, reason
            end
            if (source ~= current or target ~= backup)
                and (source ~= backup or target ~= current) then
                return nil, "invalidPath"
            end
            local sourceBytes, sourceReason = readXml(source, MAX_BYTES)
            if sourceBytes == nil then return nil, sourceReason end
            local copyOk, copied = pcall(copy, source, target, true)
            if not copyOk or copied == false then
                return nil, "copyFailed"
            end
            local targetBytes = readXml(target, MAX_BYTES)
            if targetBytes == nil or targetBytes ~= sourceBytes then
                return nil, "copyFailed"
            end
            return true
        end,
        remove = function(path)
            if path == candidate then candidateBytes = nil return true end
            if path == backup then return true end
            return nil, "invalidPath"
        end
    }
end

local function validSystem(system)
    if type(system) ~= "table" or getmetatable(system) ~= nil then return false end
    local count = 0
    for name, operation in next, system do
        count = count + 1
        if (name ~= "read" and name ~= "write" and name ~= "rename"
            and name ~= "remove") or type(operation) ~= "function" then
            return false
        end
    end
    return count == 4
end

local function call(operation, ...)
    local ok, first, second = pcall(operation, ...)
    if not ok then return nil, "operationThrew" end
    if first == true and second == nil then return true end
    if type(first) == "string" and second == nil then return first end
    if first == nil and type(second) == "string" then return nil, second end
    return nil, "invalidReturn"
end

function SavegameFilePort.new(directory, system, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    if not validDirectory(directory) then return nil, "invalidSavegameDirectory" end
    local current = join(directory, CURRENT_NAME)
    local candidate = join(directory, CANDIDATE_NAME)
    local backup = join(directory, BACKUP_NAME)
    if system == nil then system = defaultSystem(current, candidate, backup) end
    if not validSystem(system) then return nil, "fileSystemUnavailable" end

    local function read(path, notFound)
        local ok, bytes, reason = pcall(system.read, path, MAX_BYTES)
        if not ok then return nil, "operationThrew" end
        if type(bytes) == "string" then return bytes end
        if reason == "notFound" and notFound then return nil, "notFound" end
        if bytes == nil and type(reason) == "string" then return nil, reason end
        return nil, "invalidReturn"
    end

    local function cleanupBackup()
        local removed, reason = call(system.remove, backup)
        if removed == true then return true end
        return nil, reason or "backupCleanupFailed"
    end

    local function verifyBytes(path, expected, mismatchReason)
        local bytes, reason = read(path, false)
        if bytes == nil then return nil, reason end
        if bytes ~= expected then return nil, mismatchReason end
        return true
    end

    local port = {}
    port.readCurrent = function()
        return read(current, true)
    end
    port.readCandidate = function()
        return read(candidate, false)
    end
    port.writeCandidate = function(bytes)
        if type(bytes) ~= "string" or #bytes == 0 or #bytes > MAX_BYTES then
            return nil, "invalidBytes"
        end
        local removed, removeReason = call(system.remove, candidate)
        if removed ~= true then return nil, removeReason or "removeFailed" end
        local written, writeReason = call(system.write, candidate, bytes)
        if written ~= true then
            call(system.remove, candidate)
            return nil, writeReason or "writeFailed"
        end
        return true
    end
    port.discardCandidate = function()
        local removed, reason = call(system.remove, candidate)
        if removed == true then return true end
        return nil, reason or "removeFailed"
    end
    port.publishCandidate = function()
        local candidateBytes, candidateReason = read(candidate, false)
        if candidateBytes == nil then return nil, candidateReason end

        local cleaned, cleanupReason = cleanupBackup()
        if cleaned ~= true then return nil, cleanupReason end
        local currentBytes, currentReason = read(current, true)
        local movedCurrent = false
        if currentBytes ~= nil then
            local moved, moveReason = call(system.rename, current, backup)
            if moved ~= true then return nil, moveReason or "backupFailed" end
            local verified, verifyReason = verifyBytes(
                backup, currentBytes, "backupBytesMismatch")
            if verified ~= true then return nil, verifyReason end
            movedCurrent = true
        elseif currentReason ~= "notFound" then
            return nil, currentReason or "currentReadFailed"
        end

        local published, publishReason = call(system.rename, candidate, current)
        if published ~= true then
            if movedCurrent then
                local restored, restoreReason = call(
                    system.rename, backup, current)
                if restored ~= true then
                    return nil, restoreReason or "rollbackFailed"
                end
                local verified, verifyReason = verifyBytes(
                    current, currentBytes, "rollbackBytesMismatch")
                if verified ~= true then return nil, verifyReason end
                cleaned, cleanupReason = cleanupBackup()
                if cleaned ~= true then return nil, cleanupReason end
            end
            return nil, publishReason or "publishFailed"
        end
        if movedCurrent then
            cleaned, cleanupReason = cleanupBackup()
            if cleaned ~= true then return nil, cleanupReason end
        end
        return true
    end

    return port
end

FieldProfitabilityLedger.Persistence.SavegameFilePort = SavegameFilePort
return SavegameFilePort
