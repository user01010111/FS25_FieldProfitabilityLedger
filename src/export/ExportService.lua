-- Stable cycle, record, and audit CSV schemas over detached ReportService DTOs.

FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Export = FieldProfitabilityLedger.Export or {}

local ExportService = {}
ExportService.__index = ExportService

local PAGE_SIZE = 100
local RECORD_PAGE_SIZE = 256

local CYCLE_COLUMNS = {
    {key="exportSchemaVersion", heading="Export schema version"},
    {key="cycleId", heading="Cycle ID"},
    {key="landKey", heading="Land ID"},
    {key="farmId", heading="Farm ID"},
    {key="farmlandId", heading="Farmland ID"},
    {key="fieldId", heading="Field ID"},
    {key="fieldKind", heading="Field kind"},
    {key="fruitType", heading="Crop"},
    {key="alias", heading="Field or parcel alias"},
    {key="state", heading="Cycle state"},
    {key="startMissionTime", heading="Cycle start mission time (ms)"},
    {key="endMissionTime", heading="Cycle end mission time (ms)"},
    {key="period", heading="Start period"},
    {key="year", heading="Start year"},
    {key="cycleAreaHa", heading="Cycle area (ha)"},
    {key="qualityClass", heading="Cycle quality"},
    {key="completeCount", heading="Complete records"},
    {key="partialCount", heading="Partial records"},
    {key="unsupportedCount", heading="Unsupported records"},
    {key="accountingClass", heading="Accounting class"},
    {key="category", heading="Category"},
    {key="amount", heading="Amount"},
    {key="unit", heading="Unit"},
    {key="direction", heading="Direction"},
    {key="recordCount", heading="Contributing records"}
}

local RECORD_COLUMNS = {
    {key="exportSchemaVersion", heading="Export schema version"},
    {key="cycleId", heading="Cycle ID"},
    {key="recordId", heading="Record ID"},
    {key="sessionId", heading="Session ID"},
    {key="recordType", heading="Record type"},
    {key="category", heading="Category"},
    {key="accountingClass", heading="Accounting class"},
    {key="qualityClass", heading="Quality"},
    {key="amount", heading="Original amount"},
    {key="adjustedAmount", heading="Adjusted amount"},
    {key="unit", heading="Unit"},
    {key="direction", heading="Direction"},
    {key="missionTime", heading="Mission time (ms)"},
    {key="observationId", heading="Observation ID"},
    {key="basisId", heading="Valuation basis record ID"},
    {key="excluded", heading="Excluded"},
    {key="includedInSummary", heading="Included in summary"},
    {key="unallocated", heading="Unallocated"},
    {key="reasons", heading="Reasons"},
    {key="references", heading="References"},
    {key="exclusionIds", heading="Exclusion IDs"},
    {key="sourceRecordId", heading="Derived from record ID"},
    {key="compatibilityProfile", heading="Runtime compatibility profile"},
    {key="priceSource", heading="Price source"},
    {key="rateSource", heading="Rate source"},
    {key="curveSource", heading="Repair curve source"},
    {key="frozenPricePerLiter", heading="Frozen price per litre"},
    {key="frozenPricePerMs", heading="Frozen price per ms"},
    {key="frozenHourlyRate", heading="Frozen hourly rate"},
    {key="fillTypeId", heading="Fill type ID"},
    {key="outputFillTypeId", heading="Harvest fill type ID"},
    {key="operatorKind", heading="Operator kind"},
    {key="operatorId", heading="Operator ID"},
    {key="objectId", heading="Vehicle or implement ID"},
    {key="objectRole", heading="Vehicle or implement role"},
    {key="leaseCandidateCount", heading="Leased objects allocated"},
    {key="damageBefore", heading="Damage before"},
    {key="damageAfter", heading="Damage after"},
    {key="derivationFormula", heading="Allocation formula"}
    ,{key="directCostKind", heading="Direct cost kind"}
    ,{key="fs25MoneyType", heading="FS25 money type"}
    ,{key="economyMultiplier", heading="Economy multiplier"}
    ,{key="helperAutobuy", heading="Helper autobuy"}
}

local AUDIT_COLUMNS = {
    {key="exportSchemaVersion", heading="Export schema version"},
    {key="cycleId", heading="Cycle ID"},
    {key="auditType", heading="Audit type"},
    {key="auditId", heading="Audit ID"},
    {key="targetId", heading="Target ID"},
    {key="delta", heading="Correction delta"},
    {key="unit", heading="Unit"},
    {key="category", heading="Category"},
    {key="authorFarmId", heading="Author farm ID"},
    {key="missionTime", heading="Mission time (ms)"},
    {key="reason", heading="Reason"}
}

local function dependencies()
    local namespace = rawget(_G, "FieldProfitabilityLedger")
    local export = type(namespace) == "table" and rawget(namespace, "Export") or nil
    local core = type(namespace) == "table" and rawget(namespace, "Core") or nil
    local csv = type(export) == "table" and rawget(export, "CsvEncoder") or nil
    local constants = type(core) == "table" and rawget(core, "Constants") or nil
    if type(csv) ~= "table" or type(csv.encode) ~= "function"
        or type(csv.newStream) ~= "function"
        or type(constants) ~= "table" then
        return nil, "exportDependencyUnavailable"
    end
    return csv, constants
end

local function joined(values)
    if type(values) ~= "table" or #values == 0 then return nil end
    return table.concat(values, "|")
end

local function metadata(record)
    local value = type(record) == "table" and record.metadata or nil
    return type(value) == "table" and value or {}
end

function ExportService.new(reportService, filePort)
    if type(reportService) ~= "table"
        or type(reportService.listCycles) ~= "function"
        or type(reportService.cycleDetail) ~= "function"
        or type(filePort) ~= "table" or type(filePort.write) ~= "function" then
        return nil, "invalidExportDependency"
    end
    local csv, reason = dependencies()
    if csv == nil then return nil, reason end
    return setmetatable({report = reportService, filePort = filePort}, ExportService)
end

local function recordRow(cycleId, record)
    local meta = metadata(record)
    local leaseCandidates = type(meta.leaseCandidates) == "table"
        and meta.leaseCandidates or meta.candidates
    return {
        exportSchemaVersion=2,
        cycleId=cycleId, recordId=record.id,
        sessionId=record.sessionId, recordType=record.recordType,
        category=record.category, accountingClass=record.accountingClass,
        qualityClass=record.qualityClass, amount=record.amount,
        adjustedAmount=record.adjustedAmount, unit=record.unit,
        direction=record.direction, missionTime=record.missionTime,
        observationId=record.observationId, basisId=record.basisId,
        excluded=record.excluded, includedInSummary=record.includedInSummary,
        unallocated=record.unallocated, reasons=joined(record.reasons),
        references=joined(record.references),
        exclusionIds=joined(record.exclusionIds),
        sourceRecordId=meta.sourceRecordId,
        compatibilityProfile=meta.compatibilityProfile,
        priceSource=meta.priceSource,
        rateSource=meta.rateSource,
        curveSource=meta.curveSource,
        frozenPricePerLiter=meta.frozenPricePerLiter,
        frozenPricePerMs=meta.frozenPricePerMs,
        frozenHourlyRate=meta.frozenHourlyRate,
        fillTypeId=meta.fillTypeId,
        outputFillTypeId=meta.outputFillTypeId,
        operatorKind=meta.operatorKind,
        operatorId=meta.operatorId,
        objectId=meta.objectId,
        objectRole=meta.role,
        leaseCandidateCount=type(leaseCandidates) == "table"
            and #leaseCandidates or nil,
        damageBefore=meta.damageBefore,
        damageAfter=meta.damageAfter,
        derivationFormula=meta.formula,
        directCostKind=meta.directCostKind,
        fs25MoneyType=meta.fs25MoneyType,
        economyMultiplier=meta.economyMultiplier,
        helperAutobuy=meta.helperAutobuy
    }
end

function ExportService:buildCycles(options)
    local csv, constants = dependencies()
    if csv == nil then return nil, constants end
    if options ~= nil and (type(options) ~= "table" or getmetatable(options) ~= nil) then
        return nil, "invalidCycleExportOptions"
    end
    local filters = {}
    for key, value in pairs(options or {}) do
        if key ~= "farmId" and key ~= "landKey" and key ~= "state"
            and key ~= "newestFirst" then
            return nil, "invalidCycleExportOptions"
        end
        filters[key] = value
    end
    local rows = {}
    local offset = 0
    filters.includeLive = false
    while true do
        filters.offset = offset
        filters.limit = PAGE_SIZE
        local report, reason = self.report:listCycles(filters)
        if report == nil then return nil, reason end
        for _, summary in ipairs(report.rows) do
        local cycle = summary.cycle
        local totals = summary.categoryTotals
        local function add(total)
            rows[#rows + 1] = {
                exportSchemaVersion=1,
                cycleId=cycle.id, landKey=cycle.landKey, farmId=cycle.farmId,
                farmlandId=cycle.farmlandId, fieldId=cycle.fieldId,
                fieldKind=cycle.fieldKind, fruitType=cycle.fruitType,
                alias=cycle.alias, state=cycle.state,
                startMissionTime=cycle.startMissionTime,
                endMissionTime=cycle.endMissionTime,
                period=cycle.startPeriod, year=cycle.startYear,
                cycleAreaHa=cycle.cycleAreaHa,
                qualityClass=summary.qualityClass,
                completeCount=summary.qualityCounts[constants.QUALITY_CLASS.Complete] or 0,
                partialCount=summary.qualityCounts[constants.QUALITY_CLASS.Partial] or 0,
                unsupportedCount=summary.qualityCounts[constants.QUALITY_CLASS.Unsupported] or 0,
                accountingClass=total and total.accountingClass or nil,
                category=total and total.category or nil,
                amount=total and total.amount or nil,
                unit=total and total.unit or nil,
                direction=total and total.direction or nil,
                recordCount=total and total.recordCount or nil
            }
        end
        if #totals == 0 then add(nil) else
            for _, total in ipairs(totals) do add(total) end
        end
        end
        local nextOffset = report.page.nextOffset
        if nextOffset == nil then break end
        if type(nextOffset) ~= "number" or nextOffset <= offset then
            return nil, "invalidExportCursor"
        end
        offset = nextOffset
    end
    return csv.encode(CYCLE_COLUMNS, rows)
end

function ExportService:buildRecords(cycleId)
    local csv, reason = dependencies()
    if csv == nil then return nil, reason end
    -- queryCycle already supports returning the complete bounded record set.
    -- Fetch it once: paging here made every page recompute all cycle aggregates,
    -- turning a 10k-record export into more than one hundred full ledger scans.
    local detail
    detail, reason = self.report:cycleDetail(cycleId, {
        includeExcluded = true, includeLive = false
    })
    if detail == nil then return nil, reason end
    local rows = {}
    for _, record in ipairs(detail.records) do
        rows[#rows + 1] = recordRow(detail.cycle.id, record)
    end
    return csv.encode(RECORD_COLUMNS, rows)
end

function ExportService:buildAudit(cycleId)
    local csv, reason = dependencies()
    if csv == nil then return nil, reason end
    local detail
    detail, reason = self.report:cycleDetail(cycleId, {
        includeExcluded = true,
        includeLive = false,
        recordLimit = 0
    })
    if detail == nil then return nil, reason end
    local rows = {}
    for _, correction in ipairs(detail.corrections) do
        rows[#rows + 1] = {
            exportSchemaVersion=1,
            cycleId=detail.cycle.id, auditType="correction",
            auditId=correction.id, targetId=correction.targetId,
            delta=correction.delta, unit=correction.unit,
            category=correction.category, authorFarmId=correction.authorFarmId,
            missionTime=correction.missionTime, reason=correction.reason
        }
    end
    for _, exclusion in ipairs(detail.exclusions) do
        rows[#rows + 1] = {
            exportSchemaVersion=1,
            cycleId=detail.cycle.id, auditType="exclusion",
            auditId=exclusion.id, targetId=exclusion.targetId,
            authorFarmId=exclusion.authorFarmId,
            missionTime=exclusion.missionTime, reason=exclusion.reason
        }
    end
    return csv.encode(AUDIT_COLUMNS, rows)
end

function ExportService:export(kind, argument)
    if kind == "records" then
        if type(self.filePort.begin) ~= "function" then
            local legacy, legacyReason = self:buildRecords(argument)
            if legacy == nil then return nil, legacyReason end
            return self.filePort:write("records", legacy)
        end
        local csv, dependencyReason = dependencies()
        if csv == nil then return nil, dependencyReason end
        local transaction, reason = self.filePort:begin("records")
        if transaction == nil then return nil, reason end
        local stream
        stream, reason = csv.newStream(RECORD_COLUMNS, function(chunk)
            return transaction:write(chunk)
        end)
        if stream == nil then transaction:abort(); return nil, reason end
        local revision = type(self.report.getCycleRevision) == "function"
            and self.report:getCycleRevision(argument, false) or nil
        local offset, expectedTotal, emitted = 0, nil, 0
        while true do
            local detail
            detail, reason = self.report:cycleDetail(argument, {
                includeExcluded=true, recordOffset=offset,
                recordLimit=RECORD_PAGE_SIZE, includeLive=false
            })
            if detail == nil then stream:abort(); transaction:abort(); return nil, reason end
            local currentRevision = type(self.report.getCycleRevision) == "function"
                and self.report:getCycleRevision(argument, false) or revision
            if revision ~= nil and currentRevision ~= revision then
                stream:abort(); transaction:abort(); return nil, "exportDataChanged"
            end
            local page = detail.recordPage or {}
            if page.offset ~= offset or type(page.total) ~= "number"
                or page.total < 0 or (expectedTotal ~= nil and page.total ~= expectedTotal) then
                stream:abort(); transaction:abort(); return nil, "invalidExportCursor"
            end
            expectedTotal = expectedTotal or page.total
            for _, record in ipairs(detail.records or {}) do
                local wrote
                wrote, reason = stream:writeRow(recordRow(detail.cycle.id, record))
                if not wrote then stream:abort(); transaction:abort(); return nil, reason end
                emitted = emitted + 1
            end
            if page.nextOffset == nil then break end
            if type(page.nextOffset) ~= "number" or page.nextOffset <= offset
                or page.nextOffset ~= offset + #(detail.records or {}) then
                stream:abort(); transaction:abort(); return nil, "invalidExportCursor"
            end
            offset = page.nextOffset
        end
        local finalRevision = type(self.report.getCycleRevision) == "function"
            and self.report:getCycleRevision(argument, false) or revision
        if emitted ~= expectedTotal or (revision ~= nil and finalRevision ~= revision) then
            stream:abort(); transaction:abort()
            return nil, revision ~= nil and finalRevision ~= revision
                and "exportDataChanged" or "invalidExportCursor"
        end
        local encoded
        encoded, reason = stream:finish()
        if encoded == nil then transaction:abort(); return nil, reason end
        local published
        published, reason = transaction:commit()
        if published == nil then return nil, reason end
        published.rows = emitted
        published.schemaVersion = 2
        return published
    end
    local contents, reason
    if kind == "cycles" then
        contents, reason = self:buildCycles(argument)
    elseif kind == "audit" then
        contents, reason = self:buildAudit(argument)
    else
        return nil, "unknownExportKind"
    end
    if contents == nil then return nil, reason end
    return self.filePort:write(kind, contents)
end

FieldProfitabilityLedger.Export.ExportService = ExportService
return ExportService
