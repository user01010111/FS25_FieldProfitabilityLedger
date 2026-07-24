-- Narrow validated single-player command boundary for player-authored ledger edits.

FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Services = FieldProfitabilityLedger.Services or {}

local LedgerCommands = {}
LedgerCommands.__index = LedgerCommands
local MAX_CAPACITY_COMPACTION_ATTEMPTS = 100

local function finiteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

function LedgerCommands.new(ledger, missionTimeProvider, closeCycleProvider,
    legacyCandidateProvider, legacyCloseProvider, capacityCompactionProvider)
    if type(ledger) ~= "table"
        or type(ledger.getCycle) ~= "function"
        or type(ledger.getRecord) ~= "function"
        or type(ledger.getAlias) ~= "function"
        or type(ledger.setAlias) ~= "function"
        or type(ledger.appendCorrection) ~= "function"
        or type(ledger.appendExclusion) ~= "function"
        or type(missionTimeProvider) ~= "function"
        or (closeCycleProvider ~= nil
            and type(closeCycleProvider) ~= "function")
        or (legacyCandidateProvider ~= nil
            and type(legacyCandidateProvider) ~= "function")
        or (legacyCloseProvider ~= nil
            and type(legacyCloseProvider) ~= "function")
        or (capacityCompactionProvider ~= nil
            and type(capacityCompactionProvider) ~= "function") then
        return nil, "invalidLedgerCommandDependencies"
    end
    return setmetatable({
        ledger = ledger,
        missionTimeProvider = missionTimeProvider,
        closeCycleProvider = closeCycleProvider,
        legacyCandidateProvider = legacyCandidateProvider,
        legacyCloseProvider = legacyCloseProvider,
        capacityCompactionProvider = capacityCompactionProvider
    }, LedgerCommands)
end

local function withCapacityCompaction(self, protectedCycleId, operation)
    local result, reason = operation()
    if result ~= nil or reason ~= "ledgerNeutralBudgetExceeded"
        or type(self.capacityCompactionProvider) ~= "function" then
        return result, reason
    end
    for _ = 1, MAX_CAPACITY_COMPACTION_ATTEMPTS do
        local ok, compacted, compactReason = pcall(
            self.capacityCompactionProvider, protectedCycleId)
        if not ok then
            return nil, "capacityCompactionProviderFailed"
        end
        if compacted == nil then
            return nil, compactReason or "capacityCompactionFailed"
        end
        if type(compacted) ~= "table" or #compacted == 0 then
            return nil, reason
        end
        result, reason = operation()
        if result ~= nil or reason ~= "ledgerNeutralBudgetExceeded" then
            return result, reason
        end
    end
    return nil, reason
end

function LedgerCommands:listLegacyClosureCandidates(options)
    if type(self.legacyCandidateProvider) ~= "function" then
        return nil, "legacyClosureUnavailable"
    end
    if options ~= nil
            and (type(options) ~= "table" or getmetatable(options) ~= nil) then
        return nil, "invalidLegacyClosureReview"
    end
    local ok, result, reason = pcall(self.legacyCandidateProvider, options)
    if not ok then
        return nil, "legacyClosureProviderFailed"
    end
    if result == nil then
        return nil, reason or "legacyClosureReviewFailed"
    end
    if type(result) ~= "table" or type(result.candidates) ~= "table" then
        return nil, "invalidLegacyClosureReview"
    end
    return result
end

function LedgerCommands:closeReviewedLegacyCycles(selections)
    if type(self.legacyCloseProvider) ~= "function" then
        return nil, "legacyClosureUnavailable"
    end
    local ok, result, reason = pcall(self.legacyCloseProvider, selections)
    if not ok then
        return nil, "legacyClosureProviderFailed"
    end
    if result == nil then
        return nil, reason or "legacyClosureFailed"
    end
    return result
end

function LedgerCommands:closeCycle(cycleId)
    local cycle, reason = self.ledger:getCycle(cycleId)
    if cycle == nil then return nil, reason end
    if cycle.state ~= "open" then return nil, "openCycleRequired" end
    if type(self.closeCycleProvider) ~= "function" then
        return nil, "cycleCloseUnavailable"
    end
    local ok, closed, closeReason = pcall(self.closeCycleProvider, cycle.id)
    if not ok then return nil, "cycleCloseFailed" end
    if closed == nil then return nil, closeReason end
    return closed
end

function LedgerCommands:getAliasForCycle(cycleId)
    local cycle, reason = self.ledger:getCycle(cycleId)
    if cycle == nil then return nil, reason end
    local alias
    alias, reason = self.ledger:getAlias(cycle.landKey)
    if alias == nil and reason ~= "aliasNotFound" then return nil, reason end
    return {
        alias = alias,
        cycleId = cycle.id,
        landKey = cycle.landKey
    }
end

function LedgerCommands:setAliasForCycle(cycleId, alias)
    local cycle, reason = self.ledger:getCycle(cycleId)
    if cycle == nil then return nil, reason end
    local accepted
    accepted, reason = withCapacityCompaction(self, nil, function()
        return self.ledger:setAlias(cycle.landKey, alias)
    end)
    if accepted == nil then return nil, reason end
    return {
        alias = accepted,
        cycleId = cycle.id,
        landKey = cycle.landKey
    }
end

function LedgerCommands:correctRecord(cycleId, recordId, delta, reasonText)
    local cycle, reason = self.ledger:getCycle(cycleId)
    if cycle == nil then return nil, reason end
    local record
    record, reason = self.ledger:getRecord(recordId)
    if record == nil then return nil, reason end
    if record.cycleId ~= cycle.id then return nil, "recordCycleMismatch" end
    local ok, missionTime = pcall(self.missionTimeProvider)
    if not ok or not finiteNumber(missionTime) then
        return nil, "missionTimeUnavailable"
    end
    return withCapacityCompaction(self, cycle.id, function()
        return self.ledger:appendCorrection({
            targetId = record.id,
            delta = delta,
            authorFarmId = cycle.farmId,
            missionTime = missionTime,
            reason = reasonText
        })
    end)
end

function LedgerCommands:excludeRecord(cycleId, recordId, reasonText)
    local cycle, reason = self.ledger:getCycle(cycleId)
    if cycle == nil then return nil, reason end
    local record
    record, reason = self.ledger:getRecord(recordId)
    if record == nil then return nil, reason end
    if record.cycleId ~= cycle.id then return nil, "recordCycleMismatch" end
    local ok, missionTime = pcall(self.missionTimeProvider)
    if not ok or not finiteNumber(missionTime) then
        return nil, "missionTimeUnavailable"
    end
    return withCapacityCompaction(self, cycle.id, function()
        return self.ledger:appendExclusion({
            targetId = record.id,
            targetKind = "record",
            authorFarmId = cycle.farmId,
            missionTime = missionTime,
            reason = reasonText
        })
    end)
end

FieldProfitabilityLedger.Services.LedgerCommands = LedgerCommands
return LedgerCommands
