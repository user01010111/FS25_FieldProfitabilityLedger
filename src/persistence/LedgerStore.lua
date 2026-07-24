FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Persistence = FieldProfitabilityLedger.Persistence or {}

local LedgerStore = {}
LedgerStore.__index = LedgerStore

local PORT_OPERATIONS = {
    discardCandidate = true,
    publishCandidate = true,
    readCandidate = true,
    readCurrent = true,
    writeCandidate = true
}

local function dependencies()
    local core = FieldProfitabilityLedger.Core
    if type(core) ~= "table" then
        return nil, nil, nil, "persistenceDependencyUnavailable"
    end
    local constants = core.Constants
    local ledger = core.Ledger
    local serialization = core.Serialization
    if type(constants) ~= "table"
        or type(constants.LIMITS) ~= "table"
        or type(constants.SCHEMA_VERSION) ~= "number"
        or type(ledger) ~= "table"
        or type(ledger.new) ~= "function"
        or type(ledger.fromNeutral) ~= "function"
        or type(serialization) ~= "table"
        or type(serialization.encode) ~= "function"
        or type(serialization.decode) ~= "function" then
        return nil, nil, nil, "persistenceDependencyUnavailable"
    end
    return constants, ledger, serialization, nil
end

local function serializationLimits(constants)
    local limits = constants.LIMITS
    local maximumNumber = math.max(
        limits.maxMoney,
        limits.maxDurationMs,
        limits.maxIdentifier
    )
    return {
        maxEncodedBytes = limits.maxEncodedBytes,
        maxDepth = limits.maxNeutralDepth,
        maxItems = math.min(limits.maxNeutralItems, limits.maxLedgerNeutralItems),
        maxNumber = maximumNumber,
        maxStringBytes = limits.textBytes
    }
end

local function boundedReason(reason, fallback)
    if type(reason) ~= "string" or #reason == 0 or #reason > 64 then
        return fallback
    end
    for index = 1, #reason do
        local byte = string.byte(reason, index)
        local accepted = (byte >= 48 and byte <= 57)
            or (byte >= 65 and byte <= 90)
            or (byte >= 97 and byte <= 122)
            or byte == 95
        if not accepted then
            return fallback
        end
    end
    return reason
end

local function invoke(operation, ...)
    local function pack(...)
        return {n = select("#", ...), ...}
    end
    local result = pack(pcall(operation, ...))
    if not result[1] then
        return nil, nil, "threw"
    end
    if result.n > 3 then
        return result[2], result[3], "invalidReturn"
    end
    return result[2], result[3], nil
end

local function readPort(operation, notFoundAllowed)
    local first, second, invocationFailure = invoke(operation)
    if invocationFailure ~= nil then
        return nil, invocationFailure
    end
    if type(first) == "string" and second == nil then
        return first, nil
    end
    if first == nil and type(second) == "string" then
        if notFoundAllowed and second == "notFound" then
            return nil, "notFound"
        end
        return nil, "reportedFailure"
    end
    return nil, "invalidReturn"
end

local function writePort(operation, ...)
    local first, second, invocationFailure = invoke(operation, ...)
    if invocationFailure ~= nil then
        return nil, invocationFailure, false
    end
    if first == true and second == nil then
        return true, nil, true
    end
    if first == true then
        return nil, "invalidReturn", true
    end
    if first == nil and type(second) == "string" then
        return nil, "reportedFailure", false
    end
    return nil, "invalidReturn", false
end

local function failureDto(operation, phase, reason, failure)
    local dto = {
        operation = operation,
        phase = phase,
        reason = reason,
        state = "failed"
    }
    if failure ~= nil then
        dto.failure = failure
    end
    return dto
end

local function dependencyFailureDto(operation, phase, reason, dependencyReason)
    local dto = failureDto(operation, phase, reason, "dependencyRejected")
    dto.dependencyReason = boundedReason(dependencyReason, "unavailableReason")
    return dto
end

local function copyLoadDiagnostics(source)
    local result = {}
    if type(source) ~= "table" then
        return result
    end
    for index = 1, #source do
        local entry = source[index]
        if type(entry) == "table" then
            local copy = {}
            local fields = {"id", "index", "kind", "omittedCount", "reason"}
            for _, field in ipairs(fields) do
                local value = rawget(entry, field)
                if type(value) == "string" or type(value) == "number" then
                    copy[field] = value
                end
            end
            result[#result + 1] = copy
        end
    end
    return result
end

local function failAfterWrite(self, primaryReason, primaryPhase, primaryFailure, dependencyReason)
    local discarded, discardFailure = writePort(self._discardCandidate)
    if discarded then
        local dto
        if dependencyReason ~= nil then
            dto = dependencyFailureDto("save", primaryPhase, primaryReason, dependencyReason)
        else
            dto = failureDto("save", primaryPhase, primaryReason, primaryFailure)
        end
        dto.candidateDiscarded = true
        dto.candidateWritten = true
        return nil, primaryReason, dto
    end

    local dto = failureDto(
        "save",
        "discardCandidate",
        "candidateCleanupFailed",
        discardFailure
    )
    dto.candidateDiscarded = false
    dto.candidateWritten = true
    dto.primaryPhase = primaryPhase
    dto.primaryReason = primaryReason
    if primaryFailure ~= nil then
        dto.primaryFailure = primaryFailure
    end
    if dependencyReason ~= nil then
        dto.dependencyReason = boundedReason(dependencyReason, "unavailableReason")
    end
    return nil, "candidateCleanupFailed", dto
end

local function callLedgerExport(ledger)
    if type(ledger) ~= "table" or type(ledger.toNeutral) ~= "function" then
        return nil, "invalidLedger"
    end
    local ok, document, reason = pcall(ledger.toNeutral, ledger)
    if not ok then
        return nil, "ledgerExportThrew"
    end
    if document == nil then
        return nil, boundedReason(reason, "ledgerExportFailed")
    end
    if reason ~= nil then
        return nil, "invalidLedgerExport"
    end
    return document
end

local function callEncode(serialization, document, limits)
    local ok, bytes, reason = pcall(serialization.encode, document, limits)
    if not ok then
        return nil, "serializationThrew"
    end
    if type(bytes) ~= "string" then
        return nil, boundedReason(reason, "serializationFailed")
    end
    if reason ~= nil then
        return nil, "invalidSerializationResult"
    end
    return bytes
end

local function callDecode(serialization, bytes, limits)
    local ok, document, reason = pcall(serialization.decode, bytes, limits)
    if not ok then
        return nil, "serializationThrew"
    end
    if document == nil then
        return nil, boundedReason(reason, "serializationFailed")
    end
    if reason ~= nil then
        return nil, "invalidSerializationResult"
    end
    return document
end

local function callLedgerFromNeutral(ledgerModule, document)
    local ok, ledger, reason = pcall(ledgerModule.fromNeutral, document)
    if not ok then
        return nil, "ledgerRebuildThrew"
    end
    if ledger == nil then
        return nil, boundedReason(reason, "ledgerRebuildFailed")
    end
    if reason ~= nil then
        return nil, "invalidLedgerRebuild"
    end
    return ledger
end

local function callLedgerNew(ledgerModule, options)
    local ok, ledger, reason = pcall(ledgerModule.new, options)
    if not ok then
        return nil, "ledgerConstructionThrew"
    end
    if ledger == nil then
        return nil, boundedReason(reason, "ledgerConstructionFailed")
    end
    if reason ~= nil then
        return nil, "invalidLedgerConstruction"
    end
    return ledger
end

local function callCapacityCompaction(
        ledgerModule, serialization, document, limits)
    local core = FieldProfitabilityLedger.Core
    local retention = type(core) == "table" and core.Retention or nil
    if type(retention) ~= "table"
        or type(retention.compactOldestClosedForCapacity) ~= "function" then
        return nil, "retentionUnavailable", 0
    end
    local detached, rebuildReason = callLedgerFromNeutral(
        ledgerModule, document)
    if detached == nil then
        return nil, rebuildReason, 0
    end
    local compactedCount = 0
    local maximumAttempts = type(detached.cycleOrder) == "table"
        and #detached.cycleOrder or 0
    for _ = 1, maximumAttempts do
        local compacted, compactReason =
            retention.compactOldestClosedForCapacity(detached)
        if compacted == nil then
            return nil, compactReason, compactedCount
        end
        if #compacted == 0 then
            return nil, "bytes_limit", compactedCount
        end
        compactedCount = compactedCount + #compacted
        local compactedDocument, exportReason = callLedgerExport(detached)
        if compactedDocument == nil then
            return nil, exportReason, compactedCount
        end
        compactedDocument.epoch = document.epoch
        local bytes, encodeReason = callEncode(
            serialization, compactedDocument, limits)
        if bytes ~= nil then
            return bytes, nil, compactedCount
        end
        if encodeReason ~= "bytes_limit" then
            return nil, encodeReason, compactedCount
        end
    end
    return nil, "bytes_limit", compactedCount
end

function LedgerStore.new(filePort)
    if type(filePort) ~= "table" or getmetatable(filePort) ~= nil then
        return nil, "invalidFilePort"
    end
    local operationCount = 0
    for name, operation in next, filePort do
        operationCount = operationCount + 1
        if PORT_OPERATIONS[name] ~= true or type(operation) ~= "function" then
            return nil, "invalidFilePort"
        end
    end
    if operationCount ~= 5 then
        return nil, "invalidFilePort"
    end

    local self = setmetatable({}, LedgerStore)
    self._discardCandidate = filePort.discardCandidate
    self._publishCandidate = filePort.publishCandidate
    self._readCandidate = filePort.readCandidate
    self._readCurrent = filePort.readCurrent
    self._writeCandidate = filePort.writeCandidate
    return self
end

function LedgerStore:stage(ledger)
    local constants, ledgerModule, serialization, dependencyReason = dependencies()
    if dependencyReason ~= nil then
        return nil, dependencyReason,
            failureDto("save", "dependencies", dependencyReason, "unavailable")
    end
    local limits = serializationLimits(constants)

    local document, exportReason = callLedgerExport(ledger)
    if document == nil then
        return nil, exportReason,
            dependencyFailureDto("save", "ledgerExport", exportReason, exportReason)
    end
    if type(document) ~= "table" or getmetatable(document) ~= nil then
        return nil, "invalidLedgerDocument",
            failureDto(
                "save",
                "ledgerExport",
                "invalidLedgerDocument",
                "invalidReturn"
            )
    end
    if rawget(document, "schemaVersion") ~= constants.SCHEMA_VERSION then
        return nil, "unsupportedSchemaVersion",
            failureDto(
                "save",
                "ledgerExport",
                "unsupportedSchemaVersion",
                "nonCurrentSchema"
            )
    end
    local bytes, encodeReason = callEncode(serialization, document, limits)
    local capacityCompactedCycles = 0
    if bytes == nil and encodeReason == "bytes_limit" then
        bytes, encodeReason, capacityCompactedCycles =
            callCapacityCompaction(
                ledgerModule, serialization, document, limits)
    end
    if bytes == nil then
        return nil, encodeReason,
            dependencyFailureDto("save", "encode", encodeReason, encodeReason)
    end

    local written, writeFailure, candidateMayExist = writePort(self._writeCandidate, bytes)
    if not written then
        if candidateMayExist then
            return failAfterWrite(
                self,
                "candidateWriteFailed",
                "writeCandidate",
                writeFailure
            )
        end
        return nil, "candidateWriteFailed",
            failureDto("save", "writeCandidate", "candidateWriteFailed", writeFailure)
    end

    local candidateBytes, candidateReadFailure = readPort(self._readCandidate, false)
    if candidateBytes == nil then
        return failAfterWrite(
            self,
            "candidateReadFailed",
            "readCandidate",
            candidateReadFailure
        )
    end
    if candidateBytes ~= bytes then
        return failAfterWrite(
            self,
            "candidateBytesMismatch",
            "compareCandidate",
            "byteMismatch"
        )
    end

    local decoded, decodeReason = callDecode(serialization, candidateBytes, limits)
    if decoded == nil then
        return failAfterWrite(
            self,
            "candidateDecodeFailed",
            "decodeCandidate",
            nil,
            decodeReason
        )
    end
    local rebuilt, rebuildReason = callLedgerFromNeutral(ledgerModule, decoded)
    if rebuilt == nil then
        return failAfterWrite(
            self,
            "candidateRebuildFailed",
            "rebuildCandidate",
            nil,
            rebuildReason
        )
    end
    local rebuiltDocument, reexportReason = callLedgerExport(rebuilt)
    if rebuiltDocument == nil then
        return failAfterWrite(
            self,
            "candidateReexportFailed",
            "reexportCandidate",
            nil,
            reexportReason
        )
    end

    -- Ledger.fromNeutral validates the exact source document internally, then
    -- rotates its observation epoch so newly observed records cannot collide
    -- after load. Candidate verification operates on a detached document and
    -- restores only that lifecycle-only field before comparing persistence
    -- bytes. Any other rebuilt drift remains byte-visible and fails closed.
    if type(decoded) == "table" and type(rebuiltDocument) == "table" then
        rebuiltDocument.epoch = decoded.epoch
    end
    local rebuiltBytes, reencodeReason = callEncode(serialization, rebuiltDocument, limits)
    if rebuiltBytes == nil then
        return failAfterWrite(
            self,
            "candidateReencodeFailed",
            "reencodeCandidate",
            nil,
            reencodeReason
        )
    end
    if rebuiltBytes ~= bytes then
        return failAfterWrite(
            self,
            "candidateRoundTripMismatch",
            "compareRoundTrip",
            "byteMismatch"
        )
    end

    return true, nil, {
        candidateVerified = true,
        capacityCompactedCycles = capacityCompactedCycles,
        encodedBytes = #bytes,
        operation = "save",
        publishedVerified = false,
        schemaVersion = constants.SCHEMA_VERSION,
        state = "staged"
    }
end

function LedgerStore:stageCurrent()
    local constants, ledgerModule, serialization, dependencyReason = dependencies()
    if dependencyReason ~= nil then
        return nil, dependencyReason,
            failureDto("save", "dependencies", dependencyReason, "unavailable")
    end
    local limits = serializationLimits(constants)
    local currentBytes, readFailure = readPort(self._readCurrent, true)
    if currentBytes == nil then
        local reason = readFailure == "notFound"
            and "currentNotFound" or "currentReadFailed"
        return nil, reason,
            failureDto("save", "readCurrent", reason, readFailure)
    end

    local decoded, decodeReason = callDecode(
        serialization, currentBytes, limits)
    if decoded == nil then
        return nil, "currentDecodeFailed",
            dependencyFailureDto(
                "save", "decodeCurrent", "currentDecodeFailed", decodeReason)
    end
    local rebuilt, rebuildReason = callLedgerFromNeutral(
        ledgerModule, decoded)
    if rebuilt == nil then
        return nil, "currentRebuildFailed",
            dependencyFailureDto(
                "save", "rebuildCurrent", "currentRebuildFailed",
                rebuildReason)
    end
    local rebuiltDocument, reexportReason = callLedgerExport(rebuilt)
    if rebuiltDocument == nil then
        return nil, "currentReexportFailed",
            dependencyFailureDto(
                "save", "reexportCurrent", "currentReexportFailed",
                reexportReason)
    end
    if type(decoded) == "table" and type(rebuiltDocument) == "table" then
        rebuiltDocument.epoch = decoded.epoch
    end
    local rebuiltBytes, reencodeReason = callEncode(
        serialization, rebuiltDocument, limits)
    if rebuiltBytes == nil then
        return nil, "currentReencodeFailed",
            dependencyFailureDto(
                "save", "reencodeCurrent", "currentReencodeFailed",
                reencodeReason)
    end
    if rebuiltBytes ~= currentBytes then
        return nil, "currentRoundTripMismatch",
            failureDto(
                "save", "compareCurrentRoundTrip",
                "currentRoundTripMismatch", "byteMismatch")
    end

    local written, writeFailure, candidateMayExist = writePort(
        self._writeCandidate, currentBytes)
    if not written then
        if candidateMayExist then
            return failAfterWrite(
                self, "candidateWriteFailed", "writeCandidate", writeFailure)
        end
        return nil, "candidateWriteFailed",
            failureDto(
                "save", "writeCandidate",
                "candidateWriteFailed", writeFailure)
    end
    local candidateBytes, candidateReadFailure = readPort(
        self._readCandidate, false)
    if candidateBytes == nil or candidateBytes ~= currentBytes then
        return failAfterWrite(
            self,
            candidateBytes == nil and "candidateReadFailed"
                or "candidateBytesMismatch",
            candidateBytes == nil and "readCandidate"
                or "compareCandidate",
            candidateBytes == nil and candidateReadFailure
                or "byteMismatch")
    end

    return true, nil, {
        candidateVerified = true,
        encodedBytes = #currentBytes,
        operation = "save",
        preservedPrevious = true,
        publishedVerified = false,
        schemaVersion = constants.SCHEMA_VERSION,
        state = "stagedPrevious"
    }
end

function LedgerStore:publishStagedTo(filePort)
    local constants, _, _, dependencyReason = dependencies()
    if dependencyReason ~= nil then
        return nil, dependencyReason,
            failureDto("save", "dependencies", dependencyReason, "unavailable")
    end
    local candidateBytes, candidateReadFailure = readPort(
        self._readCandidate, false)
    if candidateBytes == nil then
        return nil, "candidateReadFailed",
            failureDto("save", "readCandidate", "candidateReadFailed",
                candidateReadFailure)
    end

    local target = self
    if filePort ~= nil then
        local targetReason
        target, targetReason = LedgerStore.new(filePort)
        if target == nil then
            return nil, targetReason,
                failureDto("save", "targetPort", targetReason, "invalidInput")
        end
        local written, writeFailure, candidateMayExist = writePort(
            target._writeCandidate, candidateBytes)
        if not written then
            if candidateMayExist then
                return failAfterWrite(target, "candidateWriteFailed",
                    "writeCandidate", writeFailure)
            end
            return nil, "candidateWriteFailed",
                failureDto("save", "writeCandidate",
                    "candidateWriteFailed", writeFailure)
        end
        local copiedBytes, copiedReadFailure = readPort(
            target._readCandidate, false)
        if copiedBytes == nil or copiedBytes ~= candidateBytes then
            return failAfterWrite(target,
                copiedBytes == nil and "candidateReadFailed"
                    or "candidateBytesMismatch",
                copiedBytes == nil and "readCandidate"
                    or "compareCandidate",
                copiedBytes == nil and copiedReadFailure or "byteMismatch")
        end
    end

    local published, publishFailure = writePort(target._publishCandidate)
    if not published then
        return failAfterWrite(
            target,
            "candidatePublishFailed",
            "publishCandidate",
            publishFailure
        )
    end
    local publishedBytes, publishedReadFailure = readPort(
        target._readCurrent, false)
    if publishedBytes == nil then
        return failAfterWrite(
            target,
            "publishedReadFailed",
            "readPublished",
            publishedReadFailure
        )
    end
    if publishedBytes ~= candidateBytes then
        return failAfterWrite(
            target,
            "publishedBytesMismatch",
            "comparePublished",
            "byteMismatch"
        )
    end
    if not rawequal(target, self) then
        writePort(self._discardCandidate)
    end

    return true, nil, {
        candidateVerified = true,
        encodedBytes = #candidateBytes,
        operation = "save",
        publishedVerified = true,
        schemaVersion = constants.SCHEMA_VERSION,
        state = "published"
    }
end

function LedgerStore:publishStaged()
    return self:publishStagedTo(nil)
end

function LedgerStore:save(ledger)
    local staged, stageReason, stageStatus = self:stage(ledger)
    if staged == nil then return nil, stageReason, stageStatus end
    return self:publishStaged()
end

function LedgerStore:load(newLedgerOptions)
    if type(newLedgerOptions) ~= "table" or getmetatable(newLedgerOptions) ~= nil then
        return nil, "invalidNewLedgerOptions",
            failureDto("load", "newLedgerOptions", "invalidNewLedgerOptions", "invalidInput")
    end
    local constants, ledgerModule, serialization, dependencyReason = dependencies()
    if dependencyReason ~= nil then
        return nil, dependencyReason,
            failureDto("load", "dependencies", dependencyReason, "unavailable")
    end

    local currentBytes, readFailure = readPort(self._readCurrent, true)
    if currentBytes == nil then
        if readFailure ~= "notFound" then
            return nil, "currentReadFailed",
                failureDto("load", "readCurrent", "currentReadFailed", readFailure)
        end
        local ledger, constructionReason = callLedgerNew(ledgerModule, newLedgerOptions)
        if ledger == nil then
            return nil, constructionReason,
                dependencyFailureDto(
                    "load",
                    "newLedger",
                    constructionReason,
                    constructionReason
                )
        end
        return ledger, nil, {
            loadDiagnostics = {},
            operation = "load",
            schemaVersion = constants.SCHEMA_VERSION,
            source = "notFound",
            state = "new"
        }
    end

    local decoded, decodeReason = callDecode(
        serialization,
        currentBytes,
        serializationLimits(constants)
    )
    if decoded == nil then
        return nil, "currentDecodeFailed",
            dependencyFailureDto("load", "decodeCurrent", "currentDecodeFailed", decodeReason)
    end
    local ledger, rebuildReason = callLedgerFromNeutral(ledgerModule, decoded)
    if ledger == nil then
        return nil, "currentRebuildFailed",
            dependencyFailureDto("load", "rebuildCurrent", "currentRebuildFailed", rebuildReason)
    end

    local diagnostics = copyLoadDiagnostics(ledger.loadDiagnostics)
    return ledger, nil, {
        encodedBytes = #currentBytes,
        loadDiagnostics = diagnostics,
        operation = "load",
        recoveredEntryCount = #diagnostics,
        schemaVersion = constants.SCHEMA_VERSION,
        source = "current",
        state = "loaded"
    }
end

FieldProfitabilityLedger.Persistence.LedgerStore = LedgerStore

return LedgerStore
