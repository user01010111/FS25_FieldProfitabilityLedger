-- Single-player machinery and labour adapter. A final vehicle-type
-- bridge brackets Motorized:updateConsumers after engine functions have been
-- copied; late state is sampled only after matching WorkArea evidence is
-- accepted.

FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Runtime = FieldProfitabilityLedger.Runtime or {}

local MachineryRuntimeAdapter = {}

local MAX_DIAGNOSTICS = 64
local MAX_OBJECTS = 128
local MAX_PENDING = 128
local MAX_PHYSICAL = 1000000000
local MAX_DURATION = 3153600000000
local MAX_MONEY = 1000000000000
local PROFILE = "fs25-1.20-motorized-effective-balance"

local classState = {installed=false, original=nil, bridgeCount=0, reason=nil,
    aiUpdateOriginal=nil, aiStopOriginal=nil}
local active = nil
-- Canonical AI segments are bounded at five seconds.  A separate one-second
-- ephemeral preview drives the GUI without increasing ledger record volume.
local AI_SEGMENT_MS = 5000
local AI_PREVIEW_MS = 1000
local diagnose

local function finite(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function integer(value, minimum, maximum)
    return finite(value) and value == math.floor(value)
        and value >= minimum and value <= maximum
end

local function token(value, maximum)
    if type(value) ~= "string" or #value == 0 or #value > maximum then
        return nil
    end
    for index = 1, #value do
        local byte = string.byte(value, index)
        if byte < 33 or byte > 126 then return nil end
    end
    return value
end

local function pack(...)
    return {n=select("#", ...), ...}
end

local unpackValues = unpack or table.unpack

local function invoke(pristine, self, arguments)
    return pack(pcall(function()
        return pristine(self, unpackValues(arguments, 1, arguments.n))
    end))
end

local function replay(invocation)
    return unpackValues(invocation, 2, invocation.n)
end

local function method(object, name, ...)
    if type(object) ~= "table" then return nil end
    local found, callback = pcall(function() return object[name] end)
    if not found or type(callback) ~= "function" then return nil end
    local values = pack(pcall(callback, object, ...))
    if values[1] ~= true then return nil end
    return replay(values)
end

local function stableId(object)
    return token(method(object, "getUniqueId"), 64)
end

local function rootVehicle(object)
    return method(object, "getRootVehicle")
        or (type(object) == "table" and rawget(object, "rootVehicle"))
        or object
end

local function missionTime()
    local provider = type(active) == "table" and type(active.port) == "table"
        and rawget(active.port, "getMissionTime") or nil
    if type(provider) == "function" then
        local ok, value = pcall(provider)
        if ok and finite(value) and value >= 0 then return value end
    end
    local mission = _G.g_currentMission
    local value = type(mission) == "table" and rawget(mission, "time") or nil
    return finite(value) and value >= 0 and value or 0
end

local function economyMultiplier()
    local manager = _G.EconomyManager
    local callback = type(manager) == "table"
        and rawget(manager, "getCostMultiplier") or nil
    if type(callback) ~= "function" then return nil end
    local ok, value = pcall(callback)
    return ok and finite(value) and value >= 0 and value or nil
end

local function jobVehicle(job)
    local parameter = type(job) == "table" and rawget(job, "vehicleParameter") or nil
    return method(parameter, "getVehicle")
end

local function isFieldWorkJob(job)
    if type(job) ~= "table" then return false end
    local class = _G.AIJobFieldWork
    if type(class) == "table" then
        local matches = method(job, "isa", class)
        if matches ~= true then return false end
    end
    return jobVehicle(job) ~= nil
end

local function rootOperating(root)
    local value = method(root, "getOperatingTime")
    if not finite(value) then value = type(root) == "table"
        and rawget(root, "operatingTime") or nil end
    return finite(value) and value >= 0 and value <= MAX_DURATION and value or nil
end

local function rootIsOperating(root)
    local value = method(root, "getIsOperating")
    if type(value) == "boolean" then return value end
    value = method(root, "getIsMotorStarted")
    return type(value) == "boolean" and value or nil
end

local function nextFactSequence(state)
    state.factSequence = state.factSequence + 1
    if state.factSequence > 2147483647 then state.factSequence = 1 end
    return state.factSequence
end

local function acceptBound(state, jobState, descriptor)
    if jobState.binding == nil or not finite(descriptor.amount)
        or descriptor.amount <= 0 then return false end
    descriptor.binding = jobState.binding
    descriptor.rootVehicleId = jobState.rootVehicleId
    descriptor.sequence = nextFactSequence(state)
    local called, record, reason = pcall(state.port.acceptBoundFact, descriptor)
    if not called or type(record) ~= "table" then
        diagnose(state, type(reason) == "string" and reason
            or "boundFactRejected", {category=descriptor.category,
            rootVehicleId=jobState.rootVehicleId})
        return false
    end
    return true
end

local function clearJobPreviews(state, jobState)
    local clear = type(state.port) == "table"
        and state.port.clearBoundPreview or nil
    if type(clear) ~= "function" then return end
    pcall(clear, jobState.labourPreviewKey)
    pcall(clear, jobState.machineryPreviewKey)
    pcall(clear, jobState.costPreviewKey)
end

local function previewDurations(jobState)
    local wallMs = missionTime() - jobState.segmentStartTime
    if not finite(wallMs) or wallMs < 0 or wallMs > MAX_DURATION then
        wallMs = 0
    end
    local labourMs = math.max(jobState.elapsedMs, wallMs)
    local machineryMs = jobState.operatingMs
    local operating = rootOperating(jobState.root)
    if operating ~= nil and jobState.segmentStartOperating ~= nil then
        local delta = operating - jobState.segmentStartOperating
        if finite(delta) and delta >= 0 and delta <= MAX_DURATION then
            machineryMs = math.max(machineryMs, delta)
        end
    end
    if rootIsOperating(jobState.root) == true then
        machineryMs = math.max(machineryMs, wallMs)
    end
    return labourMs, machineryMs
end

local function publishJobPreview(state, jobState, force)
    if jobState.binding == nil then return false end
    local labourMs, machineryMs = previewDurations(jobState)
    if labourMs <= 0 then return false end
    if not force and labourMs - jobState.lastPreviewElapsed < AI_PREVIEW_MS then
        return false
    end
    local preview = type(state.port) == "table"
        and state.port.previewBoundFact or nil
    if type(preview) ~= "function" then return false end
    local function publish(key, accountingClass, category, amount, unit,
        direction)
        if amount > 0 then
            local ok, accepted = pcall(preview, {
                previewKey=key, binding=jobState.binding,
                accountingClass=accountingClass, category=category,
                amount=amount, unit=unit, direction=direction
            })
            return ok and accepted ~= nil
        end
        local clear = state.port.clearBoundPreview
        if type(clear) == "function" then pcall(clear, key) end
        return true
    end
    local pendingCost = 0
    for _, settlement in ipairs(jobState.settlements) do
        pendingCost = pendingCost + settlement.amount
    end
    local labour = publish(jobState.labourPreviewKey, "Observed",
        "aiLabourTime", labourMs, "milliseconds")
    local machinery = publish(jobState.machineryPreviewKey, "Observed",
        "workingTime", machineryMs, "milliseconds")
    local cost = publish(jobState.costPreviewKey, "Direct",
        "directObservedCost", pendingCost, "money", "expense")
    jobState.lastPreviewElapsed = labourMs
    return labour or machinery or cost
end

local function flushJob(state, jobState, lifecycle)
    clearJobPreviews(state, jobState)
    if jobState.binding == nil then
        if lifecycle == "stop" and (jobState.elapsedMs > 0
            or #jobState.settlements > 0) then
            diagnose(state, "aiJobUnallocated", {
                rootVehicleId=jobState.rootVehicleId, jobId=jobState.jobId})
        end
        return false
    end
    jobState.segmentOrdinal = jobState.segmentOrdinal + 1
    local suffix = tostring(jobState.segmentOrdinal)
    local metadata = {compatibilityProfile="fs25-1.20-ai-job",
        authoritativeAIJob=true, jobId=jobState.jobId,
        operatorKind="ai", operatorId=jobState.operatorId,
        actualStartMissionTime=jobState.segmentStartTime,
        actualEndMissionTime=missionTime(), lifecycle=lifecycle}
    if jobState.elapsedMs > 0 then
        acceptBound(state, jobState, {discriminator="ait-" .. suffix,
            recordType="labour", category="aiLabourTime",
            accountingClass="Observed", qualityClass="Complete",
            amount=jobState.elapsedMs, unit="milliseconds", reasons={},
            metadata=metadata})
    end
    if jobState.operatingMs > 0 then
        acceptBound(state, jobState, {discriminator="aim-" .. suffix,
            recordType="machinery", category="workingTime",
            accountingClass="Observed", qualityClass="Complete",
            amount=jobState.operatingMs, unit="milliseconds", reasons={},
            metadata={compatibilityProfile="fs25-1.20-ai-job",
                authoritativeAIJob=true, jobId=jobState.jobId,
                measure="operatingTimeDelta", operatorKind="ai",
                operatorId=jobState.operatorId,
                actualStartMissionTime=jobState.segmentStartTime,
                actualEndMissionTime=missionTime(), lifecycle=lifecycle}})
    end
    for _, settlement in ipairs(jobState.settlements) do
        jobState.settlementOrdinal = jobState.settlementOrdinal + 1
        acceptBound(state, jobState, {
            discriminator="aiw-" .. tostring(jobState.settlementOrdinal),
            recordType="allocation", category="directObservedCost",
            accountingClass="Direct", qualityClass="Complete",
            amount=settlement.amount, unit="money", direction="expense",
            reasons={}, source="AIJob.updateCost",
            transactionId=jobState.jobId .. "-w-"
                .. tostring(jobState.settlementOrdinal),
            metadata={compatibilityProfile="fs25-1.20-ai-job",
                directCostKind="aiLabour", fs25MoneyType="AI",
                economyMultiplier=settlement.economyMultiplier,
                helperAutobuy=false, authoritative=true,
                jobId=jobState.jobId,
                transactionMissionTime=settlement.missionTime}})
    end
    jobState.elapsedMs, jobState.operatingMs, jobState.settlements = 0, 0, {}
    jobState.lastPreviewElapsed = 0
    jobState.segmentStartTime = missionTime()
    jobState.segmentStartOperating = rootOperating(jobState.root)
    return true
end

local function getJobState(state, job, create)
    local found = state.jobs[job]
    if found ~= nil or not create or not isFieldWorkJob(job) then return found end
    local vehicle = jobVehicle(job)
    local root = rootVehicle(vehicle)
    local rootId = stableId(root)
    local farmId = rawget(job, "startedFarmId")
    if rootId == nil or not integer(farmId, 1, 2147483647) then return nil end
    state.jobOrdinal = state.jobOrdinal + 1
    local rawId = rawget(job, "jobId")
    local fallbackJobId = tostring(state.jobOrdinal)
    local jobId = fallbackJobId
    if type(rawId) == "string" or finite(rawId) then
        local candidate = string.gsub(tostring(rawId), "[^%w_.%-]", "_")
        jobId = token(candidate, 64) or fallbackJobId
    end
    local helper = rawget(job, "helperIndex")
    local previewPrefix = rootId .. ":" .. jobId .. ":"
        .. tostring(state.jobOrdinal)
    found = {job=job, jobId=jobId, root=root, rootVehicleId=rootId,
        farmId=farmId, operatorId="helper-" .. tostring(helper or "unknown"),
        elapsedMs=0, operatingMs=0, lastOperating=rootOperating(root),
        settlements={}, segmentOrdinal=0, settlementOrdinal=0,
        segmentStartTime=missionTime(),
        segmentStartOperating=rootOperating(root),
        binding=nil, lastPreviewElapsed=0,
        labourPreviewKey=previewPrefix .. ":labour",
        machineryPreviewKey=previewPrefix .. ":machinery",
        costPreviewKey=previewPrefix .. ":cost"}
    state.jobs[job] = found
    return found
end

function MachineryRuntimeAdapter.observeMoneyCall(self, pristine, amount,
    farmId, moneyType, ...)
    local invocation = invoke(pristine, self, pack(amount, farmId, moneyType, ...))
    if invocation[1] ~= true then error(invocation[2], 0) end
    local state = active
    local context = state ~= nil and state.producerContext or nil
    local types = _G.MoneyType
    if context ~= nil and finite(amount) and amount < 0
        and farmId == context.farmId and type(types) == "table" then
        if context.kind == "aiWage" and moneyType == rawget(types, "AI") then
            context.settlements[#context.settlements + 1] = {
                amount=-amount, missionTime=missionTime(),
                economyMultiplier=economyMultiplier()}
        elseif context.kind == "motorConsumer"
            and moneyType == rawget(types, "PURCHASE_FUEL") then
            context.settlements[#context.settlements + 1] = {
                amount=-amount, missionTime=missionTime(), moneyType=moneyType}
        end
    end
    return replay(invocation)
end

function MachineryRuntimeAdapter.observeAIUpdateCost(job, pristine, dt, ...)
    local state = active
    if state == nil or state.disabled then return pristine(job, dt, ...) end
    local jobState = getJobState(state, job, true)
    local running = jobState ~= nil and rawget(job, "isRunning") == true
    if not running or not finite(dt) or dt < 0 or dt > MAX_DURATION then
        return pristine(job, dt, ...)
    end
    local context = {kind="aiWage", farmId=jobState.farmId, settlements={}}
    local previous = state.producerContext
    state.producerContext = context
    local invocation = invoke(pristine, job, pack(dt, ...))
    state.producerContext = previous
    if invocation[1] ~= true then error(invocation[2], 0) end
    jobState.elapsedMs = jobState.elapsedMs + dt
    local operating = rootOperating(jobState.root)
    local operatingIncrement = 0
    if operating ~= nil and jobState.lastOperating ~= nil then
        local delta = operating - jobState.lastOperating
        if finite(delta) and delta >= 0 and delta <= dt * 2 then
            operatingIncrement = delta
        end
    end
    -- AIJob:updateCost can run before the vehicle operating
    -- counter advances.  Treat an actively operating root as authoritative for
    -- this paid job interval; retain the counter delta when it is substantial.
    if rootIsOperating(jobState.root) == true
        and (operatingIncrement < dt * 0.25 or operatingIncrement > dt * 2) then
        operatingIncrement = dt
    end
    if finite(operatingIncrement) and operatingIncrement > 0 then
        jobState.operatingMs = jobState.operatingMs + operatingIncrement
    end
    jobState.lastOperating = operating
    for _, settlement in ipairs(context.settlements) do
        jobState.settlements[#jobState.settlements + 1] = settlement
    end
    if jobState.binding ~= nil and jobState.elapsedMs >= AI_SEGMENT_MS then
        flushJob(state, jobState, "active")
    elseif jobState.binding ~= nil then
        publishJobPreview(state, jobState, false)
    end
    return replay(invocation)
end

function MachineryRuntimeAdapter.observeAIStop(job, pristine, ...)
    local state = active
    if state == nil or state.disabled then return pristine(job, ...) end
    local jobState = getJobState(state, job, true)
    local context = jobState ~= nil and {kind="aiWage",
        farmId=jobState.farmId, settlements={}} or nil
    local previous = state.producerContext
    if context ~= nil then state.producerContext = context end
    local invocation = invoke(pristine, job, pack(...))
    state.producerContext = previous
    if invocation[1] ~= true then error(invocation[2], 0) end
    if jobState ~= nil then
        for _, settlement in ipairs(context.settlements) do
            jobState.settlements[#jobState.settlements + 1] = settlement
        end
        flushJob(state, jobState, "stop")
        state.jobs[job] = nil
        jobState.job, jobState.root = nil, nil
    end
    return replay(invocation)
end

diagnose = function(state, code, context)
    local row = {code=type(code) == "string" and code or "machineryFailure",
        context={}}
    if type(context) == "table" then
        for key, value in pairs(context) do
            if type(key) == "string" and (type(value) == "string"
                or type(value) == "number" or type(value) == "boolean") then
                row.context[key] = value
            end
        end
    end
    if #state.diagnostics < MAX_DIAGNOSTICS then
        state.diagnostics[#state.diagnostics + 1] = row
    else
        state.omittedDiagnostics = math.min(2147483647,
            state.omittedDiagnostics + 1)
    end
    if type(state.port.diagnose) == "function" then
        pcall(state.port.diagnose, row.code, row.context)
    end
end

local function bindingsCurrent()
    return classState.installed and classState.bridgeCount > 0
end

local function authoritative(state, object)
    local ok, value = pcall(state.port.isAuthoritative, object)
    return ok and value == true
end

local function currentSequence(state)
    local ok, value = pcall(state.port.getSequence)
    return ok and integer(value, 1, 2147483647) and value or nil
end

local function pendingKey(rootVehicleId, serverSequence)
    return rootVehicleId .. "\31" .. tostring(serverSequence)
end

local function fillName(fillType)
    local manager = _G.g_fillTypeManager
    return token(method(manager, "getFillTypeNameByIndex", fillType), 128)
end

local function consumerCategory(fillType)
    local values = _G.FillType
    if type(values) ~= "table" then return nil end
    if fillType == rawget(values, "DIESEL") then return "fuel" end
    if fillType == rawget(values, "DEF") then return "def" end
    return nil
end

local function consumerSnapshots(vehicle, rootId)
    local spec = type(vehicle) == "table" and rawget(vehicle, "spec_motorized") or nil
    local consumers = type(spec) == "table" and rawget(spec, "consumers") or nil
    if type(consumers) ~= "table" then return nil end
    local rows = {}
    for _, consumer in pairs(consumers) do
        if type(consumer) == "table" then
            local fillType = rawget(consumer, "fillType")
            local category = consumerCategory(fillType)
            local unitIndex = rawget(consumer, "fillUnitIndex")
            local pending = rawget(consumer, "fillLevelToChange")
            local level = integer(unitIndex, 1, 2147483647)
                and method(vehicle, "getFillUnitFillLevel", unitIndex) or nil
            local name = category ~= nil and fillName(fillType) or nil
            if category ~= nil and finite(level) and level >= 0
                and level <= MAX_PHYSICAL and finite(pending)
                and math.abs(pending) <= MAX_PHYSICAL and name ~= nil then
                local effective = level - pending
                if finite(effective) and effective >= 0
                    and effective <= MAX_PHYSICAL then
                    rows[#rows + 1] = {
                        category=category,
                        consumerId=rootId .. "-" .. category .. "-" .. tostring(unitIndex),
                        fillName=name,
                        effective=effective
                    }
                end
            end
        end
    end
    table.sort(rows, function(left, right)
        if left.category ~= right.category then return left.category < right.category end
        return left.consumerId < right.consumerId
    end)
    return rows
end

local function helperConsumerConsumptions(vehicle, dt)
    if not finite(dt) or dt < 0 then return {} end
    local spec = type(vehicle) == "table" and rawget(vehicle, "spec_motorized") or nil
    local motor = type(spec) == "table" and rawget(spec, "motor") or nil
    local consumers = type(spec) == "table" and rawget(spec, "consumers") or nil
    if type(motor) ~= "table" or type(consumers) ~= "table" then return {} end
    local rpm = rawget(motor, "lastMotorRpm")
    local minimum, maximum = rawget(motor, "minRpm"), rawget(motor, "maxRpm")
    local load = rawget(spec, "smoothedLoadPercentage")
    if not finite(rpm) or not finite(minimum) or not finite(maximum)
        or maximum <= minimum or not finite(load) then return {} end
    local rpmPercentage = (rpm - minimum) / (maximum - minimum)
    local rpmFactor = 0.5 + rpmPercentage * 0.5
    local loadFactor = math.max(load * rpmPercentage, 0)
    local motorFactor = 0.5 * ((0.2 * rpmFactor) + (1.8 * loadFactor))
    local missionInfo = type(_G.g_currentMission) == "table"
        and rawget(g_currentMission, "missionInfo") or nil
    local fuelUsage = type(missionInfo) == "table"
        and rawget(missionInfo, "fuelUsage") or nil
    local usageFactor = fuelUsage == 1 and 1 or (fuelUsage == 3 and 2.5 or 1.5)
    local damage = method(vehicle, "getVehicleDamage") or 0
    local damagedIncrease = type(_G.Motorized) == "table"
        and rawget(Motorized, "DAMAGED_USAGE_INCREASE") or 0
    if finite(damage) and damage > 0 and finite(damagedIncrease) then
        usageFactor = usageFactor * (1 + damage * damagedIncrease)
    end
    local result = {}
    for _, consumer in pairs(consumers) do
        local category = type(consumer) == "table"
            and consumerCategory(rawget(consumer, "fillType")) or nil
        local pending = type(consumer) == "table"
            and rawget(consumer, "fillLevelToChange") or nil
        local usage = type(consumer) == "table" and rawget(consumer, "usage") or nil
        if category ~= nil and rawget(consumer, "permanentConsumption") == true
            and finite(pending) and finite(usage) and usage > 0 then
            local total = pending + usageFactor * motorFactor * usage * dt
            if finite(total) and math.abs(total) > 1 and total > 0 then
                result[category] = (result[category] or 0) + total
            end
        end
    end
    return result
end

local function objectSnapshot(object, role)
    local objectId = stableId(object)
    if objectId == nil then return nil end
    local operating = method(object, "getOperatingTime")
    if not finite(operating) then operating = rawget(object, "operatingTime") end
    if not finite(operating) or operating < 0 or operating > MAX_DURATION then
        operating = 0
    end
    local damage = method(object, "getDamageAmount")
    if not finite(damage) or damage < 0 or damage > 1 then damage = 0 end
    local wear = method(object, "getWearTotalAmount")
    if not finite(wear) or wear < 0 or wear > 1 then wear = 0 end
    local price = method(object, "getPrice")
    if not finite(price) or price < 0 or price > MAX_MONEY then price = nil end
    local repair = nil
    local wearable = _G.Wearable
    local calculateRepair = type(wearable) == "table"
        and rawget(wearable, "calculateRepairPrice") or nil
    if price ~= nil and type(calculateRepair) == "function" then
        local ok, value = pcall(calculateRepair, price, damage)
        if ok and finite(value) and value >= 0 and value <= MAX_MONEY then
            repair = value
        end
    end
    local leasePrice, runningLeasingFactor = nil, nil
    local propertyStates = _G.VehiclePropertyState
    if type(propertyStates) == "table"
        and rawget(object, "propertyState") == rawget(propertyStates, "LEASED")
        and price ~= nil then
        local manager = _G.g_storeManager
        local filename = rawget(object, "configFileName")
        local item = type(filename) == "string"
            and method(manager, "getItemByXMLFilename", filename) or nil
        local factor = type(item) == "table"
            and rawget(item, "runningLeasingFactor") or nil
        if finite(factor) and factor >= 0 and factor <= 2 then
            leasePrice, runningLeasingFactor = price, factor
        end
    end
    return {object=object, objectId=objectId, role=role,
        operating=operating, damage=damage, wear=wear, repair=repair,
        leasePrice=leasePrice, runningLeasingFactor=runningLeasingFactor}
end

local function objectSnapshots(root)
    local result, seen = {}, {}
    local function add(object, role)
        if type(object) ~= "table" or seen[object] or #result >= MAX_OBJECTS then
            return
        end
        seen[object] = true
        local snapshot = objectSnapshot(object, role)
        if snapshot ~= nil then result[#result + 1] = snapshot end
    end
    add(root, "root")
    local children = type(root) == "table" and rawget(root, "childVehicles") or nil
    if type(children) == "table" then
        for index = 1, #children do add(children[index], "implement") end
    end
    table.sort(result, function(left, right) return left.objectId < right.objectId end)
    return result
end

local function stageConsumerDelta(state, rootId, serverSequence, before, after)
    local afterById = {}
    for _, row in ipairs(after or {}) do afterById[row.consumerId] = row end
    local rows = {}
    for _, row in ipairs(before or {}) do
        local current = afterById[row.consumerId]
        if current ~= nil and current.category == row.category
            and current.fillName == row.fillName then
            rows[#rows + 1] = {
                category=row.category, consumerId=row.consumerId,
                fillName=row.fillName, beforeEffective=row.effective,
                afterEffective=current.effective
            }
        end
    end
    local ok, reason = state.meter:stageConsumers({
        authority=true, complete=true, rootVehicleId=rootId,
        serverSequence=serverSequence, rows=rows
    })
    if ok == nil then
        diagnose(state, reason or "consumerStageRejected", {
            rootVehicleId=rootId, serverSequence=serverSequence})
        return nil, reason or "consumerStageRejected"
    end
    return true
end

local function prunePendingOrder(state)
    local order = state.pendingOrder
    local head = state.pendingHead
    while head <= #order and state.pending[order[head]] == nil do
        head = head + 1
    end
    local tail = #order
    local span = head <= tail and tail - head + 1 or 0
    if head > MAX_PENDING * 2 or span > MAX_PENDING * 2 then
        local compact, retained = {}, {}
        for index = tail, head, -1 do
            local key = order[index]
            if state.pending[key] ~= nil and not retained[key] then
                retained[key] = true
                compact[#compact + 1] = key
            end
        end
        for left = 1, math.floor(#compact / 2) do
            local right = #compact - left + 1
            compact[left], compact[right] = compact[right], compact[left]
        end
        state.pendingOrder = compact
        state.pendingHead = 1
    else
        state.pendingHead = head
    end
end

local function discardPending(state, key)
    local pending = state.pending[key]
    if pending == nil then return true, false end
    state.pending[key] = nil
    state.pendingCount = math.max(0, state.pendingCount - 1)
    for _, object in ipairs(pending.objects or {}) do object.object = nil end
    pending.root = nil
    local discarded, reason = state.meter:discardSequence({
        authority=true, rootVehicleId=pending.rootVehicleId,
        serverSequence=pending.serverSequence
    })
    if discarded == nil then
        diagnose(state, reason or "pendingDiscardRejected", {
            rootVehicleId=pending.rootVehicleId,
            serverSequence=pending.serverSequence})
        return nil, reason or "pendingDiscardRejected"
    end
    return true, true
end

local function evictOldestPending(state)
    prunePendingOrder(state)
    local key = state.pendingOrder[state.pendingHead]
    if key == nil then return nil, "pendingOrderUnavailable" end
    state.pendingHead = state.pendingHead + 1
    return discardPending(state, key)
end

function MachineryRuntimeAdapter.observeVehicleCall(self, pristine, ...)
    local state = active
    if state == nil or state.disabled then return pristine(self, ...) end
    local root = rootVehicle(self)
    local rootId = stableId(root)
    local serverSequence = currentSequence(state)
    local isAuthoritative = authoritative(state, self)
    if not isAuthoritative or not rawequal(root, self)
        or rootId == nil or serverSequence == nil then
        return pristine(self, ...)
    end
    local key = pendingKey(rootId, serverSequence)
    local beforeConsumers = consumerSnapshots(self, rootId)
    local beforeObjects = objectSnapshots(root)
    local farmId = method(self, "getOwnerFarmId")
        or method(root, "getOwnerFarmId") or rawget(root, "ownerFarmId")
    local missionInfo = type(_G.g_currentMission) == "table"
        and rawget(g_currentMission, "missionInfo") or nil
    local helperAutobuy = method(self, "getIsAIActive") == true
        and type(missionInfo) == "table"
        and rawget(missionInfo, "helperBuyFuel") == true
    local motorContext = integer(farmId, 1, 2147483647)
        and {kind="motorConsumer", farmId=farmId, settlements={},
            helperAutobuy=helperAutobuy,
            helperConsumptions=helperAutobuy
                and helperConsumerConsumptions(self, select(1, ...)) or {}} or nil
    local previousContext = state.producerContext
    if motorContext ~= nil then state.producerContext = motorContext end
    local invocation = invoke(pristine, self, pack(...))
    state.producerContext = previousContext
    if invocation[1] ~= true then error(invocation[2], 0) end
    if active == state and not state.disabled then
        if state.pending[key] == nil then
            while state.pendingCount >= MAX_PENDING do
                if evictOldestPending(state) == nil then break end
            end
            local staged = stageConsumerDelta(state, rootId, serverSequence,
                beforeConsumers, consumerSnapshots(self, rootId))
            if staged ~= nil then
                state.pending[key] = {root=root, rootVehicleId=rootId,
                    serverSequence=serverSequence, objects=beforeObjects,
                    purchaseFuelSettlements=motorContext
                        and motorContext.settlements or {},
                    helperAutobuy=helperAutobuy,
                    helperConsumptions=motorContext
                        and motorContext.helperConsumptions or {}}
                state.pendingCount = state.pendingCount + 1
                state.pendingOrder[#state.pendingOrder + 1] = key
                prunePendingOrder(state)
            else
                for _, object in ipairs(beforeObjects or {}) do object.object = nil end
            end
        else
            diagnose(state, "duplicateConsumerSequence", {
                rootVehicleId=rootId, serverSequence=serverSequence})
        end
    end
    return replay(invocation)
end

function MachineryRuntimeAdapter.installClassWrapper(...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    if classState.installed then return true, false end
    local pristine = type(_G.Motorized) == "table"
        and Motorized.updateConsumers or nil
    local aiUpdate = type(_G.AIJob) == "table" and AIJob.updateCost or nil
    local aiStop = type(_G.AIJob) == "table" and AIJob.stop or nil
    if type(pristine) ~= "function" then
        classState.reason = "machineryClassUnavailable"
        return nil, classState.reason
    end
    classState.original = pristine
    if type(aiUpdate) == "function" and type(aiStop) == "function" then
        classState.aiUpdateOriginal = aiUpdate
        classState.aiStopOriginal = aiStop
        AIJob.updateCost = function(job, dt, ...)
            return MachineryRuntimeAdapter.observeAIUpdateCost(job, aiUpdate, dt, ...)
        end
        AIJob.stop = function(job, ...)
            return MachineryRuntimeAdapter.observeAIStop(job, aiStop, ...)
        end
    end
    classState.installed = true
    classState.reason = nil
    return true, true
end

function MachineryRuntimeAdapter.registerVehicleBridge(...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    if not classState.installed then
        return nil, classState.reason or "machineryClassUnavailable"
    end
    classState.bridgeCount = classState.bridgeCount + 1
    return true, classState.bridgeCount
end

function MachineryRuntimeAdapter.activate(port, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    if active ~= nil then
        if rawequal(active.port, port) then return true, false end
        return nil, "machineryAlreadyActive"
    end
    if classState.aiUpdateOriginal == nil and type(_G.AIJob) == "table"
        and type(AIJob.updateCost) == "function"
        and type(AIJob.stop) == "function" then
        local aiUpdate, aiStop = AIJob.updateCost, AIJob.stop
        classState.aiUpdateOriginal, classState.aiStopOriginal = aiUpdate, aiStop
        AIJob.updateCost = function(job, dt, ...)
            return MachineryRuntimeAdapter.observeAIUpdateCost(job, aiUpdate, dt, ...)
        end
        AIJob.stop = function(job, ...)
            return MachineryRuntimeAdapter.observeAIStop(job, aiStop, ...)
        end
    end
    if type(port) ~= "table" or getmetatable(port) ~= nil
        or type(port.isSinglePlayer) ~= "function"
        or type(port.isAuthoritative) ~= "function"
        or type(port.getSequence) ~= "function"
        or type(port.acceptObservedFact) ~= "function" then
        return nil, "invalidMachineryPort"
    end
    local ok, supported = pcall(port.isSinglePlayer)
    if not ok or supported ~= true then return nil, "unsupportedRole" end
    if not bindingsCurrent() then
        return nil, classState.reason or "machineryBindingsUnavailable"
    end
    local adapters = FieldProfitabilityLedger.Adapters
    local meterClass = type(adapters) == "table" and adapters.MachineryMeter or nil
    if type(meterClass) ~= "table" or type(meterClass.new) ~= "function" then
        return nil, "machineryMeterUnavailable"
    end
    local meter, reason = meterClass.new({
        maxPhysical=MAX_PHYSICAL, maxDurationMs=MAX_DURATION,
        maxMoney=MAX_MONEY, maxRatio=1, diagnosticCapacity=64,
        maxPending=128, maxObjects=MAX_OBJECTS, maxReasons=16,
        maxTextBytes=256
    })
    if meter == nil then return nil, reason end
    if type(meter.discardSequence) ~= "function" then
        return nil, "machineryMeterUnavailable"
    end
    local mission = _G.g_currentMission
    local addMoney = type(mission) == "table" and mission.addMoney or nil
    active = {port=port, meter=meter, pending={}, pendingCount=0,
        pendingOrder={}, pendingHead=1,
        diagnostics={}, omittedDiagnostics=0, disabled=false,
        jobs=setmetatable({}, {__mode="k"}), jobOrdinal=0, factSequence=0,
        producerContext=nil, mission=mission, moneyOriginal=addMoney}
    local installedState = active
    if type(addMoney) == "function" and type(port.acceptBoundFact) == "function" then
        installedState.moneyWrapper = function(self, ...)
            return MachineryRuntimeAdapter.observeMoneyCall(self, addMoney, ...)
        end
        mission.addMoney = installedState.moneyWrapper
    end
    return true, true
end

local function operationDiscriminator(update)
    local selected = nil
    for index = 1, #update.operations do
        local operation = update.operations[index]
        local value = type(operation) == "table"
            and token(operation.observationDiscriminator, 64) or nil
        if value ~= nil and (selected == nil or value < selected) then
            selected = value
        end
    end
    return selected
end

local function updateBinding(update)
    local result = type(update.results) == "table" and update.results[1] or nil
    local cycle = type(result) == "table" and result.cycle or nil
    local session = type(result) == "table" and result.session or nil
    local record = type(result) == "table" and result.record or nil
    if type(cycle) ~= "table" or type(session) ~= "table"
        or type(record) ~= "table" or type(cycle.id) ~= "string"
        or type(session.id) ~= "string" or type(record.id) ~= "string"
        or not integer(cycle.farmId, 1, 2147483647) then return nil end
    return {cycleId=cycle.id, sessionId=session.id, farmId=cycle.farmId,
        missionTime=record.missionTime or update.missionTime,
        recordId=record.id}
end

local function bindJobs(state, update, binding)
    if binding == nil then return false end
    local bound = false
    for _, jobState in pairs(state.jobs) do
        if jobState.rootVehicleId == update.rootVehicleId
            and jobState.farmId == binding.farmId then
            jobState.binding = binding
            bound = true
            if jobState.elapsedMs >= AI_SEGMENT_MS then
                flushJob(state, jobState, "fieldBound")
            else
                publishJobPreview(state, jobState, true)
            end
        end
    end
    return bound
end

local function acceptFact(state, update, discriminator, suffix, recordType,
    category, amount, unit, metadata)
    if not finite(amount) or amount <= 0 then return false end
    local called, record, reason = pcall(state.port.acceptObservedFact, {
        rootVehicleId=update.rootVehicleId,
        serverSequence=update.serverSequence,
        observationDiscriminator=suffix,
        operationObservationDiscriminator=discriminator,
        recordType=recordType, category=category, amount=amount, unit=unit,
        qualityClass="Complete", reasons={}, metadata=metadata or {
            compatibilityProfile=PROFILE}
    })
    if not called or type(record) ~= "table" then
        diagnose(state, type(reason) == "string" and reason
            or "machineryFactRejected", {category=category,
            rootVehicleId=update.rootVehicleId,
            serverSequence=update.serverSequence})
        return false
    end
    return true
end

function MachineryRuntimeAdapter.onAcceptedUpdate(update, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state = active
    if state == nil then return true, 0 end
    if type(update) ~= "table" or getmetatable(update) ~= nil
        or token(update.rootVehicleId, 64) == nil
        or not integer(update.serverSequence, 1, 2147483647)
        or not finite(update.activeMs) or update.activeMs < 0
        or update.activeMs > MAX_DURATION
        or type(update.implementIds) ~= "table"
        or (update.operatorKind ~= "player" and update.operatorKind ~= "ai"
            and update.operatorKind ~= "unknown")
        or type(update.operations) ~= "table" then
        return nil, "invalidAcceptedUpdate"
    end
    local discriminator = operationDiscriminator(update)
    if discriminator == nil then return nil, "acceptedOperationMissing" end
    local binding = updateBinding(update)
    local authoritativeAiJob = bindJobs(state, update, binding)
    local key = pendingKey(update.rootVehicleId, update.serverSequence)
    local pending = state.pending[key]
    local purchaseFuelSettlements = pending ~= nil
        and pending.purchaseFuelSettlements or {}
    local helperAutobuy = pending ~= nil and pending.helperAutobuy == true
    local helperConsumptions = pending ~= nil and pending.helperConsumptions or {}
    local allocationBasis = {}
    if pending ~= nil then
        state.pending[key] = nil
        state.pendingCount = math.max(0, state.pendingCount - 1)
        for _, before in ipairs(pending.objects) do
            allocationBasis[before.objectId] = {
                leasePrice=before.leasePrice,
                runningLeasingFactor=before.runningLeasingFactor,
                repairBefore=before.repair,
                damageBefore=before.damage
            }
            local after = objectSnapshot(before.object, before.role)
            if after ~= nil and after.objectId == before.objectId then
                local staged, reason = state.meter:stageObject({
                    authority=true, rootVehicleId=update.rootVehicleId,
                    serverSequence=update.serverSequence,
                    objectId=before.objectId, role=before.role,
                    operatingBefore=before.operating,
                    operatingAfter=after.operating,
                    damageBefore=before.damage, damageAfter=after.damage,
                    wearBefore=before.wear, wearAfter=after.wear,
                    repairValueBefore=before.repair or 0,
                    repairValueAfter=after.repair or (before.repair or 0)
                })
                allocationBasis[before.objectId].repairAfter = after.repair
                allocationBasis[before.objectId].damageAfter = after.damage
                if staged == nil then diagnose(state,
                    reason or "objectStageRejected", {objectId=before.objectId}) end
            end
            before.object = nil
        end
        pending.root = nil
    end
    local tagged, tagReason = state.meter:tagEvidence({
        complete=true, rootVehicleId=update.rootVehicleId,
        serverSequence=update.serverSequence, activeMs=update.activeMs,
        landUpdateToken="accepted-" .. tostring(update.serverSequence),
        operatorKind=update.operatorKind, operatorId=update.operatorId,
        implementIds=update.implementIds, quality="Complete", reasons={}
    })
    if tagged == nil then
        diagnose(state, tagReason or "machineryEvidenceRejected", {
            rootVehicleId=update.rootVehicleId,
            serverSequence=update.serverSequence})
        return true, 0
    end
    local fact, factReason = state.meter:finalizeSequence({
        authority=true, rootVehicleId=update.rootVehicleId,
        serverSequence=update.serverSequence})
    if fact == nil then
        diagnose(state, factReason or "machineryFinalizeRejected", {
            rootVehicleId=update.rootVehicleId,
            serverSequence=update.serverSequence})
        return true, 0
    end
    local accepted = 0
    local helperFuelDirectAccepted = false
    if binding ~= nil then
        local holder = {binding=binding, rootVehicleId=update.rootVehicleId}
        for index, settlement in ipairs(purchaseFuelSettlements) do
            local directAccepted = acceptBound(state, holder, {
                discriminator="hfd-" .. tostring(update.serverSequence)
                    .. "-" .. tostring(index),
                recordType="allocation", category="directObservedCost",
                accountingClass="Direct", qualityClass="Complete",
                amount=settlement.amount, unit="money", direction="expense",
                reasons={}, source="Motorized.updateConsumers",
                transactionId=update.rootVehicleId .. "-f-"
                    .. tostring(update.serverSequence) .. "-" .. tostring(index),
                metadata={compatibilityProfile="fs25-1.20-helper-autobuy",
                    directCostKind="helperBuyFuel",
                    fs25MoneyType="PURCHASE_FUEL", helperAutobuy=true,
                    authoritative=true,
                    transactionMissionTime=settlement.missionTime}})
            if directAccepted then
                accepted = accepted + 1
                helperFuelDirectAccepted = true
            end
        end
    end
    if helperAutobuy then
        for _, category in ipairs({"fuel", "def"}) do
            local amount = helperConsumptions[category]
            if finite(amount) and amount > 0 and acceptFact(state, update,
                discriminator, category == "fuel" and "mhf" or "mhd",
                "machinery", category, amount, "litres",
                {compatibilityProfile="fs25-1.20-helper-autobuy",
                    fillTypeId=category == "fuel" and FillType.DIESEL
                        or FillType.DEF,
                    fillName=category == "fuel" and "DIESEL" or "DEF",
                    helperAutobuy=true,
                    authoritativeDirectCost=category == "fuel"
                        and helperFuelDirectAccepted or false,
                    directCostKind=category == "fuel"
                        and "helperBuyFuel" or nil,
                    noFs25DirectCharge=category == "def" or nil,
                    physicalSource="Motorized.updateConsumersFormula"}) then
                accepted = accepted + 1
            end
        end
    end
    for index, consumer in ipairs(fact.consumers) do
        local consumerCode = consumer.category == "fuel" and "f" or "d"
        if not helperAutobuy and consumer.status == "consumed"
            and acceptFact(state, update,
            discriminator, "m" .. consumerCode .. tostring(index),
            "machinery", consumer.category, consumer.consumedLitres,
            "litres", {compatibilityProfile=helperAutobuy
                    and "fs25-1.20-helper-autobuy" or PROFILE,
                consumerId=consumer.consumerId, fillName=consumer.fillName,
                fillTypeId=consumer.category == "fuel" and FillType.DIESEL
                    or FillType.DEF,
                helperAutobuy=helperAutobuy,
                authoritativeDirectCost=consumer.category == "fuel"
                    and helperFuelDirectAccepted or false,
                directCostKind=consumer.category == "fuel"
                    and helperAutobuy and "helperBuyFuel" or nil,
                noFs25DirectCharge=consumer.category == "def"
                    and helperAutobuy or nil}) then
            accepted = accepted + 1
        end
    end
    local leaseCandidates = {}
    for _, object in ipairs(fact.objects) do
        local basis = allocationBasis[object.objectId]
        if basis ~= nil and basis.leasePrice ~= nil
            and basis.runningLeasingFactor ~= nil
            and finite(object.operatingMs) and object.operatingMs > 0 then
            leaseCandidates[#leaseCandidates + 1] = {
                objectId=object.objectId, role=object.role,
                activeOperatingMs=object.operatingMs,
                priceBasis=basis.leasePrice,
                runningLeasingFactor=basis.runningLeasingFactor
            }
        end
    end
    if not (update.operatorKind == "ai" and authoritativeAiJob)
        and acceptFact(state, update, discriminator, "mt", "machinery",
        "workingTime", fact.workingTimeMs, "milliseconds",
        {compatibilityProfile=PROFILE, measure="acceptedActiveTime",
            leaseCandidates=leaseCandidates}) then
        accepted = accepted + 1
    end
    for index, object in ipairs(fact.objects) do
        if acceptFact(state, update, discriminator, "mw" .. tostring(index),
            "machinery", "wearDelta", object.wearDelta, "ratio",
            {compatibilityProfile=PROFILE, objectId=object.objectId,
                role=object.role,
                damageBefore=allocationBasis[object.objectId]
                    and allocationBasis[object.objectId].damageBefore or nil,
                damageAfter=allocationBasis[object.objectId]
                    and allocationBasis[object.objectId].damageAfter or nil,
                repairLiabilityAmount=object.repairLiability,
                repairLiabilitySupported=allocationBasis[object.objectId] ~= nil
                    and allocationBasis[object.objectId].repairBefore ~= nil
                    and allocationBasis[object.objectId].repairAfter ~= nil}) then
            accepted = accepted + 1
        end
    end
    local labourCategory = fact.operatorKind == "ai" and "aiLabourTime"
        or (fact.operatorKind == "player" and "playerLabourTime" or nil)
    local labourAmount = labourCategory == "aiLabourTime"
        and fact.aiLabourMs or fact.playerLabourMs
    if labourCategory ~= nil
        and not (labourCategory == "aiLabourTime" and authoritativeAiJob)
        and acceptFact(state, update, discriminator,
        labourCategory == "aiLabourTime" and "ma" or "mp",
        "labour", labourCategory, labourAmount,
        "milliseconds", {compatibilityProfile=PROFILE,
            operatorKind=fact.operatorKind,
            operatorId=fact.operatorId or "unresolved"}) then
        accepted = accepted + 1
    end
    return true, accepted
end

function MachineryRuntimeAdapter.discardUpdate(
    rootVehicleId, serverSequence, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state = active
    if state == nil then return true, false end
    local root = token(rootVehicleId, 64)
    if root == nil or not integer(serverSequence, 1, 2147483647) then
        return nil, "invalidMachineryUpdate"
    end
    return discardPending(state, pendingKey(root, serverSequence))
end

-- FS25 may defer AIJob:updateCost for tens of seconds and settle the entire
-- authoritative duration when the helper stops. Drive only the ephemeral GUI
-- preview from mission time while a field-bound job is running; canonical
-- records and direct costs remain exclusively updateCost/addMoney-derived.
function MachineryRuntimeAdapter.update(...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state = active
    if state == nil then return true, false end
    local changed = false
    for job, jobState in pairs(state.jobs) do
        if jobState.binding ~= nil and type(job) == "table"
            and rawget(job, "isRunning") == true
            and publishJobPreview(state, jobState, false) then
            changed = true
        end
    end
    return true, changed
end

function MachineryRuntimeAdapter.abortLifecycle(lifecycle, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state = active
    if state == nil then return true, false end
    for job, jobState in pairs(state.jobs) do
        flushJob(state, jobState, lifecycle)
        jobState.lastOperating = rootOperating(jobState.root)
        if lifecycle == "unload" then
            state.jobs[job] = nil
            jobState.job, jobState.root = nil, nil
        end
    end
    local ok, reason = state.meter:abortLifecycle(lifecycle)
    if ok == nil then return nil, reason or "machineryLifecycleRejected" end
    for _, pending in pairs(state.pending) do
        for _, object in ipairs(pending.objects or {}) do object.object = nil end
        pending.root = nil
    end
    state.pending = {}
    state.pendingCount = 0
    state.pendingOrder = {}
    state.pendingHead = 1
    if lifecycle == "unload" then
        if type(state.mission) == "table"
            and state.mission.addMoney == state.moneyWrapper then
            state.mission.addMoney = state.moneyOriginal
        end
        state.mission, state.moneyOriginal, state.moneyWrapper = nil, nil, nil
        active = nil
    end
    return true, true
end

function MachineryRuntimeAdapter.getStatus(...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state = active
    local rows = {}
    local pendingJobs = 0
    if state ~= nil then
        for index, row in ipairs(state.diagnostics) do
            local context = {}
            for key, value in pairs(row.context) do context[key] = value end
            rows[index] = {code=row.code, context=context}
        end
        for _ in pairs(state.jobs) do pendingJobs = pendingJobs + 1 end
    end
    return {active=state ~= nil, bindingsInstalled=bindingsCurrent(),
        classContractInstalled=classState.installed,
        vehicleBridgeCount=classState.bridgeCount,
        aiJobContractInstalled=classState.aiUpdateOriginal ~= nil
            and classState.aiStopOriginal ~= nil,
        moneyObserverInstalled=state ~= nil and state.moneyWrapper ~= nil,
        pendingJobs=pendingJobs,
        disabled=state ~= nil and state.disabled or false,
        pendingUpdates=state ~= nil and state.pendingCount or 0,
        diagnostics=rows,
        omittedDiagnostics=state ~= nil and state.omittedDiagnostics or 0,
        reason=classState.reason}
end

FieldProfitabilityLedger.Runtime.MachineryRuntimeAdapter =
    MachineryRuntimeAdapter
return MachineryRuntimeAdapter
