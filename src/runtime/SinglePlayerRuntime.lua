-- Mission lifecycle for the supported single-player runtime.

FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Runtime = FieldProfitabilityLedger.Runtime or {}

local SinglePlayerRuntime = {}
local installed = false
local saveHookMission = nil
local saveHookMissionInfo = nil
local state = nil
local pendingSaveState = nil
local diagnostics = {}
local MAX_DIAGNOSTICS = 64

local function log(kind, message)
    local logging = _G.Logging
    local method = type(logging) == "table" and logging[kind] or nil
    if type(method) == "function" then
        pcall(method, "[FieldProfitabilityLedger] " .. message)
    elseif type(_G.print) == "function" then
        print("[FieldProfitabilityLedger] " .. message)
    end
end

local function diagnose(code, context)
    local row = {code = code, context = {}}
    if type(context) == "table" then
        for key, value in pairs(context) do
            if type(key) == "string" and (type(value) == "string"
                or type(value) == "number" or type(value) == "boolean") then
                row.context[key] = value
            end
        end
    end
    if #diagnostics < MAX_DIAGNOSTICS then
        diagnostics[#diagnostics + 1] = row
    else
        table.remove(diagnostics, 1)
        diagnostics[#diagnostics + 1] = row
    end
end

local function dependencies()
    local namespace = FieldProfitabilityLedger
    local core = rawget(namespace, "Core")
    local persistence = rawget(namespace, "Persistence")
    local adapters = rawget(namespace, "Adapters")
    local runtime = rawget(namespace, "Runtime")
    local gui = rawget(namespace, "Gui")
    local coordinator = type(core) == "table"
        and rawget(core, "OperationCoordinator") or nil
    local constants = type(core) == "table"
        and rawget(core, "Constants") or nil
    local attribution = type(core) == "table"
        and rawget(core, "FieldAttribution") or nil
    local retention = type(core) == "table"
        and rawget(core, "Retention") or nil
    local store = type(persistence) == "table"
        and rawget(persistence, "LedgerStore") or nil
    local filePort = type(persistence) == "table"
        and rawget(persistence, "SavegameFilePort") or nil
    local workArea = type(adapters) == "table"
        and rawget(adapters, "WorkAreaAdapter") or nil
    local application = type(runtime) == "table"
        and rawget(runtime, "ApplicationRuntimeAdapter") or nil
    local harvest = type(runtime) == "table"
        and rawget(runtime, "HarvestRuntimeAdapter") or nil
    local machinery = type(runtime) == "table"
        and rawget(runtime, "MachineryRuntimeAdapter") or nil
    local economics = type(runtime) == "table"
        and rawget(runtime, "EconomicsRuntimeAdapter") or nil
    local collector = type(runtime) == "table"
        and rawget(runtime, "WorkAreaCollector") or nil
    local guiController = type(gui) == "table"
        and rawget(gui, "GuiController") or nil
    if type(constants) ~= "table" or type(rawget(constants, "LIMITS")) ~= "table"
        or type(rawget(constants.LIMITS, "maxMissionTime")) ~= "number"
        or type(rawget(constants.LIMITS, "maxIdentifier")) ~= "number"
        or type(rawget(constants.LIMITS, "maxQueryRows")) ~= "number"
        or type(rawget(constants.LIMITS, "idBytes")) ~= "number"
        or type(coordinator) ~= "table" or type(coordinator.new) ~= "function"
        or type(coordinator.acceptFactOnly) ~= "function"
        or type(store) ~= "table" or type(store.new) ~= "function"
        or type(filePort) ~= "table" or type(filePort.new) ~= "function"
        or type(workArea) ~= "table" or type(workArea.install) ~= "function"
        or type(workArea.uninstall) ~= "function"
        or type(application) ~= "table"
        or type(application.activate) ~= "function"
        or type(application.abortLifecycle) ~= "function"
        or type(application.augmentUpdate) ~= "function"
        or type(application.discardUpdate) ~= "function"
        or type(application.onAcceptedUpdate) ~= "function"
        or type(application.getStatus) ~= "function"
        or type(harvest) ~= "table"
        or type(harvest.activate) ~= "function"
        or type(harvest.abortLifecycle) ~= "function"
        or type(harvest.augmentUpdate) ~= "function"
        or type(harvest.discardUpdate) ~= "function"
        or type(harvest.onAcceptedUpdate) ~= "function"
        or type(harvest.getStatus) ~= "function"
        or type(machinery) ~= "table"
        or type(machinery.activate) ~= "function"
        or type(machinery.update) ~= "function"
        or type(machinery.abortLifecycle) ~= "function"
        or type(machinery.discardUpdate) ~= "function"
        or type(machinery.onAcceptedUpdate) ~= "function"
        or type(machinery.getStatus) ~= "function"
        or type(economics) ~= "table"
        or type(economics.activate) ~= "function"
        or type(economics.abortLifecycle) ~= "function"
        or type(economics.onObservedRecord) ~= "function"
        or type(economics.getStatus) ~= "function"
        or type(attribution) ~= "table"
        or type(attribution.resolve) ~= "function"
        or type(retention) ~= "table"
        or type(retention.compactOldestClosedForCapacity) ~= "function"
        or type(collector) ~= "table" or type(collector.collect) ~= "function"
        or type(collector.collectApplicationAttributionSnapshots) ~= "function"
        or type(collector.collectAttributionSnapshots) ~= "function"
        or type(collector.collectSowingAttributionSnapshots) ~= "function"
        or type(collector.register) ~= "function"
        or type(collector.unregister) ~= "function"
        or type(collector.reset) ~= "function"
        or type(guiController) ~= "table"
        or type(guiController.install) ~= "function"
        or type(guiController.uninstall) ~= "function"
        or type(guiController.getStatus) ~= "function" then
        return nil, "runtimeDependencyUnavailable"
    end
    return {
        constants = constants, coordinator = coordinator, attribution = attribution,
        retention = retention,
        store = store, filePort = filePort, workArea = workArea,
        application = application, harvest = harvest, collector = collector,
        machinery = machinery, economics = economics,
        guiController = guiController
    }
end

local function mission()
    local value = _G.g_currentMission
    return type(value) == "table" and value or nil
end

local function isSinglePlayerMission()
    local value = mission()
    if value == nil then return false end
    local getIsServer = value.getIsServer
    local dynamic = rawget(value, "missionDynamicInfo")
    if type(getIsServer) ~= "function" or type(dynamic) ~= "table"
        or type(rawget(dynamic, "isMultiplayer")) ~= "boolean" then
        return false
    end
    local ok, server = pcall(getIsServer, value)
    return ok and server == true and dynamic.isMultiplayer == false
end

local function rawMissionTime()
    local value = mission()
    local time = value ~= nil and rawget(value, "time") or nil
    if type(time) ~= "number" or time ~= time or time < 0 then return 0 end
    return time
end

local function missionTime()
    local rawTime = rawMissionTime()
    local clockState = state or pendingSaveState
    local offset = type(clockState) == "table"
        and rawget(clockState, "missionTimeOffset") or nil
    if type(offset) ~= "number" or offset < 0 then offset = 0 end
    return rawTime + offset
end

local function savegameDirectory(missionInfo)
    local directory = type(missionInfo) == "table"
        and rawget(missionInfo, "savegameDirectory") or nil
    if directory == nil then
        local value = mission()
        local info = value ~= nil and rawget(value, "missionInfo") or nil
        directory = type(info) == "table"
            and rawget(info, "savegameDirectory") or nil
    end
    return directory
end

local function installMissionSaveHook()
    local current = mission()
    if current == nil then return nil, "saveMissionUnavailable" end
    local info = rawget(current, "missionInfo")
    if rawequal(saveHookMission, current)
        and rawequal(saveHookMissionInfo, info) then return true, false end
    local pristine = current.saveSavegame
    local infoPristine = type(info) == "table" and info.saveToXMLFile or nil
    local utils = _G.Utils
    if type(pristine) ~= "function" or type(infoPristine) ~= "function"
        or type(utils) ~= "table"
        or type(rawget(utils, "prependedFunction")) ~= "function"
        or type(rawget(utils, "appendedFunction")) ~= "function" then
        return nil, "saveLifecycleUnavailable"
    end
    -- Validate and retain the candidate in memory before FS25 starts saving.
    -- FS25 then clears the savegame directory. Publication must therefore
    -- happen from the active mission-info serializer inside that save phase.
    local wrapped = utils.prependedFunction(pristine, function(savedMission)
        local missionInfo = type(savedMission) == "table"
            and rawget(savedMission, "missionInfo") or nil
        if missionInfo == nil then
            local activeMission = mission()
            missionInfo = activeMission ~= nil
                and rawget(activeMission, "missionInfo") or nil
        end
        log("info", "save boundary reached")
        SinglePlayerRuntime:saveToXMLFile(missionInfo)
    end)
    local infoWrapped = utils.appendedFunction(infoPristine, function(savedInfo)
        log("info", "save publication boundary reached")
        SinglePlayerRuntime:publishSaveToXMLFile(savedInfo)
    end)
    if type(wrapped) ~= "function" or type(infoWrapped) ~= "function" then
        return nil, "saveLifecycleUnavailable"
    end
    local infoAssigned = pcall(function() info.saveToXMLFile = infoWrapped end)
    if not infoAssigned
        or not rawequal(rawget(info, "saveToXMLFile"), infoWrapped) then
        return nil, "saveLifecycleUnavailable"
    end
    local assigned = pcall(function() current.saveSavegame = wrapped end)
    if not assigned or not rawequal(rawget(current, "saveSavegame"), wrapped) then
        pcall(function() info.saveToXMLFile = infoPristine end)
        return nil, "saveLifecycleUnavailable"
    end
    saveHookMission = current
    saveHookMissionInfo = info
    return true, true
end

local function deactivate(reason)
    local deps = state ~= nil and state.deps or dependencies()
    if deps ~= nil then
        pcall(deps.guiController.uninstall)
        pcall(deps.application.abortLifecycle, "unload")
        pcall(deps.harvest.abortLifecycle, "unload")
        pcall(deps.machinery.abortLifecycle, "unload")
        pcall(deps.economics.abortLifecycle, "unload")
        pcall(deps.workArea.uninstall)
        pcall(deps.collector.reset)
    end
    if state ~= nil and state.coordinator ~= nil then
        pcall(state.deps.coordinator.checkpoint,
            state.coordinator, reason or "unload", missionTime())
    end
    state = nil
    saveHookMission = nil
    saveHookMissionInfo = nil
end

local function adapterPort(activeState)
    local function discardObservers(rootVehicleId, serverSequence, reason)
        local applicationOk, applicationReason =
            activeState.deps.application.discardUpdate(
                rootVehicleId, serverSequence, reason)
        local machineryOk, machineryReason =
            activeState.deps.machinery.discardUpdate(
                rootVehicleId, serverSequence)
        local harvestOk, harvestReason =
            activeState.deps.harvest.discardUpdate(
                rootVehicleId, serverSequence)
        if applicationOk == nil then
            diagnose(applicationReason or "applicationDiscardUpdateFailed",
                {phase="applicationDiscard"})
        end
        if machineryOk == nil then
            diagnose(machineryReason or "machineryDiscardUpdateFailed",
                {phase="machineryDiscard"})
        end
        if harvestOk == nil then
            diagnose(harvestReason or "harvestDiscardUpdateFailed",
                {phase="harvestDiscard"})
        end
        return true
    end

    return {
        isSinglePlayer = isSinglePlayerMission,
        isAuthoritative = function(object)
            return isSinglePlayerMission() and type(object) == "table"
                and rawget(object, "isServer") == true
        end,
        getCompleteUpdate = function(root, dt)
            local update, reason, failedRootId, failedSequence =
                activeState.deps.collector.collect(root, dt)
            if update == nil then
                if type(failedRootId) == "string"
                    and type(failedSequence) == "number" then
                    discardObservers(failedRootId, failedSequence, reason)
                end
                return nil, reason
            end
            update.missionTime = missionTime()
            local augmented
            augmented, reason = activeState.deps.application.augmentUpdate(
                root, update)
            if augmented == nil then
                discardObservers(
                    update.rootVehicleId, update.serverSequence, reason)
                return nil, reason
            end
            update = augmented
            augmented, reason = activeState.deps.harvest.augmentUpdate(
                root, update)
            if augmented == nil then
                discardObservers(
                    update.rootVehicleId, update.serverSequence, reason)
                return nil, reason
            end
            return augmented
        end,
        acceptWork = function(command)
            return activeState.deps.coordinator.acceptWork(
                activeState.coordinator, command)
        end,
        acceptFactOnly = function(fact)
            return activeState.deps.coordinator.acceptFactOnly(
                activeState.coordinator, fact)
        end,
        acceptObservedFact = function(fact)
            local record, createdOrReason =
                activeState.deps.coordinator.acceptObservedFact(
                activeState.coordinator, fact)
            if record ~= nil then
                local valued, valuationReason =
                    activeState.deps.economics.onObservedRecord(record)
                if valued == nil then
                    diagnose(valuationReason or "economicsRecordFailed", {
                        category=record.category, phase="economics"})
                end
            end
            return record, createdOrReason
        end,
        acceptBoundFact = function(fact)
            if type(fact) ~= "table" or type(fact.binding) ~= "table" then
                return nil, "invalidBoundFact"
            end
            local binding = fact.binding
            local observationId, reason = activeState.ledger:createObservationId(
                fact.rootVehicleId, fact.sequence, fact.discriminator)
            if observationId == nil then return nil, reason end
            local accountingClass = fact.accountingClass or "Observed"
            local command = {
                cycleId=binding.cycleId, sessionId=binding.sessionId,
                recordType=fact.recordType, category=fact.category,
                accountingClass=accountingClass,
                qualityClass=fact.qualityClass or "Complete",
                amount=fact.amount, unit=fact.unit, direction=fact.direction,
                missionTime=binding.missionTime,
                observationId=observationId, basisId=fact.basisId,
                reasons=fact.reasons or {}, metadata=fact.metadata or {},
                references=fact.references or {binding.recordId}
            }
            if accountingClass == "Direct" then
                command.directProvenance = {
                    authoritative=true, source=fact.source,
                    transactionId=fact.transactionId,
                    transactionGeneration=activeState.ledger.epoch,
                    farmId=binding.farmId
                }
            end
            local record, createdOrReason = activeState.ledger:acceptRecord(command)
            if record ~= nil and accountingClass == "Observed" then
                local valued, valuationReason =
                    activeState.deps.economics.onObservedRecord(record)
                if valued == nil then diagnose(
                    valuationReason or "economicsRecordFailed",
                    {category=record.category, phase="economics"}) end
            end
            return record, createdOrReason
        end,
        previewBoundFact = function(fact)
            if type(fact) ~= "table" or type(fact.binding) ~= "table"
                or type(fact.previewKey) ~= "string" then
                return nil, "invalidBoundPreview"
            end
            return activeState.ledger:setLiveFact(fact.previewKey, {
                cycleId=fact.binding.cycleId,
                accountingClass=fact.accountingClass or "Observed",
                category=fact.category, amount=fact.amount,
                unit=fact.unit, direction=fact.direction
            })
        end,
        clearBoundPreview = function(previewKey)
            return activeState.ledger:clearLiveFact(previewKey)
        end,
        getSequence = function() return _G.g_updateLoopIndex end,
        getMissionTime = missionTime,
        getAttributionSnapshots =
            activeState.deps.collector.collectAttributionSnapshots,
        getApplicationAttributionSnapshots =
            activeState.deps.collector.collectApplicationAttributionSnapshots,
        getSowingAttributionSnapshots =
            activeState.deps.collector.collectSowingAttributionSnapshots,
        resolveAttribution = activeState.deps.attribution.resolve,
        areaToHa = function(area)
            local missionValue = mission()
            local pixels = missionValue ~= nil
                and missionValue.getFruitPixelsToSqm or nil
            local mathUtil = _G.MathUtil
            local convert = type(mathUtil) == "table" and mathUtil.areaToHa or nil
            if type(pixels) ~= "function" or type(convert) ~= "function" then
                return nil, "harvestAreaApiUnavailable"
            end
            local ok, scale = pcall(pixels, missionValue)
            if not ok then return nil, "harvestAreaApiUnavailable" end
            return convert(area, scale)
        end,
        closeRoot = function(rootVehicleId, reason, time)
            return activeState.deps.coordinator.closeRoot(
                activeState.coordinator, rootVehicleId, reason, time)
        end,
        diagnose = diagnose,
        registerSealedListener = activeState.deps.collector.register,
        unregisterSealedListener = activeState.deps.collector.unregister,
        onAcceptedUpdate = function(update)
            local machineryOk, machineryReason =
                activeState.deps.machinery.onAcceptedUpdate(update)
            local applicationOk, applicationReason =
                activeState.deps.application.onAcceptedUpdate(update)
            local harvestOk, harvestedOrReason =
                activeState.deps.harvest.onAcceptedUpdate(update)
            if machineryOk == nil then
                diagnose(machineryReason or "machineryAcceptedUpdateFailed",
                    {phase="machinery"})
            end
            if applicationOk == nil then
                diagnose(applicationReason or "applicationAcceptedUpdateFailed",
                    {phase="application"})
            end
            if harvestOk == nil then
                diagnose(harvestedOrReason or "harvestAcceptedUpdateFailed",
                    {phase="harvest"})
            end
            return true
        end,
        onAcceptedFactOnly = function(update)
            local applicationOk, applicationReason =
                activeState.deps.application.onAcceptedUpdate(update)
            local machineryOk, machineryReason =
                activeState.deps.machinery.discardUpdate(
                    update.rootVehicleId, update.serverSequence)
            local harvestOk, harvestReason =
                activeState.deps.harvest.discardUpdate(
                    update.rootVehicleId, update.serverSequence)
            if applicationOk == nil then
                diagnose(applicationReason or "applicationAcceptedUpdateFailed",
                    {phase="applicationFactOnly"})
            end
            if machineryOk == nil then
                diagnose(machineryReason or "machineryDiscardUpdateFailed",
                    {phase="machineryFactOnly"})
            end
            if harvestOk == nil then
                diagnose(harvestReason or "harvestDiscardUpdateFailed",
                    {phase="harvestFactOnly"})
            end
            return true
        end,
        onDiscardedUpdate = discardObservers,
        parcelFallbackEnabled = true
    }
end

local function economicsPort()
    local function price(methodName, fillTypeId, ...)
        local value = mission()
        local manager = value ~= nil and rawget(value, "economyManager") or nil
        local callback = type(manager) == "table" and manager[methodName] or nil
        if type(callback) ~= "function" then return nil end
        local ok, result = pcall(callback, manager, fillTypeId, ...)
        if not ok or type(result) ~= "number" or result ~= result
            or result < 0 or result == math.huge then return nil end
        return result
    end
    return {
        getReplacementPrice = function(fillTypeId)
            return price("getCostPerLiter", fillTypeId, false)
        end,
        getHarvestPrice = function(fillTypeId)
            return price("getPricePerLiter", fillTypeId)
        end,
        getAiLabourPricePerMs = function()
            local base = 0.0005
            local economy = _G.EconomyManager
            local multiplier = type(economy) == "table"
                and rawget(economy, "getCostMultiplier") or nil
            if type(multiplier) == "function" then
                local ok, value = pcall(multiplier)
                if ok and type(value) == "number" and value == value
                    and value >= 0 and value < math.huge then
                    return base * value
                end
            end
            return nil
        end,
        resolveFillType = function(name)
            local manager = _G.g_fillTypeManager
            local callback = type(manager) == "table"
                and rawget(manager, "getFillTypeIndexByName") or nil
            if type(callback) ~= "function" then return nil end
            local ok, result = pcall(callback, manager, name)
            return ok and result or nil
        end
    }
end

local function installGui(activeState, reportFailure)
    activeState.guiAttempts = activeState.guiAttempts + 1
    local installed, reason = activeState.deps.guiController.install(
        activeState.ledger, function()
            local application = activeState.deps.application.getStatus()
            local harvest = activeState.deps.harvest.getStatus()
            local machinery = activeState.deps.machinery.getStatus()
            local economics = activeState.deps.economics.getStatus()
            return {
                fieldWork = state == activeState,
                application = type(application) == "table"
                    and application.active == true and application.disabled ~= true,
                harvest = type(harvest) == "table"
                    and harvest.active == true and harvest.disabled ~= true,
                machinery = type(machinery) == "table"
                    and machinery.active == true and machinery.disabled ~= true,
                economics = type(economics) == "table"
                    and economics.active == true,
                capacityCompactedCycles =
                    activeState.capacityCompactedForEdits
                    + (activeState.lastSaveStatus ~= nil
                    and activeState.lastSaveStatus.capacityCompactedCycles
                    or 0),
                saveState = activeState.lastSaveStatus ~= nil
                    and activeState.lastSaveStatus.state or nil
            }
        end, function(cycleId)
            return SinglePlayerRuntime.closeCycle(cycleId)
end, function(options)
return SinglePlayerRuntime.listLegacyClosureCandidates(options)
        end, function(selections)
            return SinglePlayerRuntime.closeReviewedLegacyCycles(selections)
        end, function(protectedCycleId)
            local compacted, compactReason =
                activeState.deps.retention.compactOldestClosedForCapacity(
                    activeState.ledger,
                    {excludeCycleId=protectedCycleId})
            if compacted == nil then return nil, compactReason end
            if #compacted > 0 then
                activeState.capacityCompactedForEdits =
                    activeState.capacityCompactedForEdits + #compacted
                log("info", string.format(
                    "compacted %d closed cycle(s) to make room for a player edit",
                    #compacted))
            end
            return compacted
        end)
    if installed ~= nil then
        activeState.guiPending = false
        return true
    end
    activeState.guiPending = activeState.guiAttempts < 20
    activeState.nextGuiAttemptTime = missionTime() + 500
    if reportFailure then
        diagnose(reason or "guiInstallFailed", {phase="gui"})
        log("warning", "ledger data is active; waiting for the in-game menu")
    elseif not activeState.guiPending then
        diagnose(reason or "guiInstallFailed", {phase="guiFinal"})
        log("warning", "ledger data is active, but the in-game page is unavailable")
    end
    return nil, reason
end

function SinglePlayerRuntime:loadMap()
    -- A prior mission that unloaded without traversing its save callback must
    -- never leak into the next mission or be published implicitly.
    pendingSaveState = nil
    deactivate("reload")
    diagnostics = {}
    if not isSinglePlayerMission() then
        diagnose("unsupportedRole", {})
        log("warning", "disabled: mission is not an authoritative single-player session")
        return
    end
    local deps, dependencyReason = dependencies()
    if deps == nil then
        diagnose(dependencyReason, {})
        log("error", "disabled: runtime dependencies are unavailable")
        return
    end
    local directory = savegameDirectory()
    local filePort, fileReason = deps.filePort.new(directory)
    if filePort == nil then
        diagnose(fileReason or "filePortUnavailable", {})
        log("error", "disabled: savegame-local storage is unavailable")
        return
    end
    local store, storeReason = deps.store.new(filePort)
    if store == nil then
        diagnose(storeReason or "storeUnavailable", {})
        log("error", "disabled: ledger store construction failed")
        return
    end
    if type(store.stage) ~= "function"
        or type(store.publishStagedTo) ~= "function" then
        diagnose("storeLifecycleUnavailable", {})
        log("error", "disabled: ledger store save lifecycle is unavailable")
        return
    end
    local ledger, loadReason, loadStatus = store:load({
        calendarYearSupported = false,
        epoch = 1
    })
    if ledger == nil then
        diagnose(loadReason or "ledgerLoadFailed", {})
        log("error", "disabled: existing ledger could not be loaded safely")
        return
    end
    if type(ledger.getMissionTimeFloor) ~= "function" then
        diagnose("missionTimeFloorUnavailable", {})
        log("error", "disabled: ledger clock continuity is unavailable")
        return
    end
    local missionTimeFloor = ledger:getMissionTimeFloor()
    local rawTime = rawMissionTime()
    local maximumTime = deps.constants.LIMITS.maxMissionTime
    if type(missionTimeFloor) ~= "number" or missionTimeFloor < 0
        or missionTimeFloor > maximumTime then
        diagnose("missionTimeFloorUnavailable", {})
        log("error", "disabled: ledger clock continuity is invalid")
        return
    end
    local missionTimeOffset = 0
    if missionTimeFloor >= rawTime then
        if missionTimeFloor >= maximumTime then
            diagnose("missionTimeExhausted", {})
            log("error", "disabled: ledger clock range is exhausted")
            return
        end
        missionTimeOffset = missionTimeFloor - rawTime + 1
    end
    local coordinator, coordinatorReason = deps.coordinator.new(ledger)
    if coordinator == nil then
        diagnose(coordinatorReason or "coordinatorUnavailable", {})
        log("error", "disabled: operation coordinator construction failed")
        return
    end
    local activeState = {
        deps = deps, filePort = filePort, store = store, ledger = ledger,
        coordinator = coordinator, loadStatus = loadStatus,
        lastSaveStatus = nil, savegameDirectory = directory,
        guiAttempts = 0, guiPending = false, nextGuiAttemptTime = 0,
        missionTimeOffset = missionTimeOffset,
        capacityCompactedForEdits = 0
    }
    state = activeState
    local saveHooked, saveHookReason = installMissionSaveHook()
    if saveHooked == nil then
        diagnose(saveHookReason or "saveLifecycleUnavailable", {phase="saveHook"})
        log("error", "disabled: mission save boundary is unavailable")
        deactivate("saveHookRejected")
        return
    end
    installGui(activeState, true)
    local ports = adapterPort(activeState)
    local economicsActive, economicsReason = deps.economics.activate(
        ledger, economicsPort())
    if economicsActive == nil then
        diagnose(economicsReason or "economicsInstallFailed", {phase="economics"})
        log("warning", "physical accounting is active; monetary estimates are unavailable")
    end
    local applicationActive, applicationReason = deps.application.activate(ports)
    if applicationActive == nil then
        diagnose(applicationReason or "applicationInstallFailed", {
            phase = "application"
        })
        log("warning", "application inputs are unavailable; field work remains active")
    end
    local harvestActive, harvestReason = deps.harvest.activate(ports)
    if harvestActive == nil then
        diagnose(harvestReason or "harvestInstallFailed", {phase="harvest"})
        log("warning", "ordinary harvest is unavailable; other field work remains active")
    end
    local machineryActive, machineryReason = deps.machinery.activate(ports)
    if machineryActive == nil then
        diagnose(machineryReason or "machineryInstallFailed", {phase="machinery"})
        log("warning", "machinery and labour measures are unavailable; field work remains active")
    end
    local active, installReason = deps.workArea.install(ports)
    if active == nil then
        diagnose(installReason or "workAreaInstallFailed", {})
        log("error", "disabled: WorkArea collector installation failed")
        deactivate("installRejected")
        return
    end
    log("info", "single-player ledger loaded")
end

function SinglePlayerRuntime:update()
    if state == nil then return end
    if state.guiPending and missionTime() >= state.nextGuiAttemptTime then
        installGui(state, false)
    end
    local _, reason = state.deps.coordinator.expire(
        state.coordinator, missionTime())
    if reason ~= nil then diagnose(reason, {phase = "expire"}) end
    local updated, updateReason = state.deps.machinery.update()
    if updated == nil then
        diagnose(updateReason or "machineryPreviewFailed", {
            phase = "livePreview"
        })
    end
end

local function setSaveFailure(target, reason)
    local failureReason = type(reason) == "string"
        and reason or "ledgerSaveFailed"
    target.lastSaveStatus = {
        failureReason = failureReason,
        newLedgerSaved = false,
        state = "failed"
    }
    target.savePrepared = false
    return failureReason
end

local function stagePreviousLedger(target, failureReason)
    local reason = setSaveFailure(target, failureReason)
    local preserved, preserveReason, preserveStatus =
        target.store:stageCurrent()
    if preserved == nil then
        diagnose(preserveReason or "previousLedgerPreservationFailed", {
            phase = "saveFallback"
        })
        return nil, reason
    end
    preserveStatus.failureReason = reason
    preserveStatus.newLedgerSaved = false
    target.lastSaveStatus = preserveStatus
    target.savePrepared = true
    return true
end

local function stageLedger()
    local target = state or pendingSaveState
    if target == nil then
        log("warning", "save skipped: no active or pending ledger")
        return
    end
    local alreadyCheckpointed = state == nil
        and rawequal(target, pendingSaveState)
    if not alreadyCheckpointed then
        local applicationAborted, applicationReason =
            target.deps.application.abortLifecycle("save")
        if applicationAborted == nil then
            diagnose(applicationReason or "applicationCheckpointFailed", {
                phase = "save"
            })
        end
        local harvestAborted, harvestReason =
            target.deps.harvest.abortLifecycle("save")
        if harvestAborted == nil then
            diagnose(harvestReason or "harvestCheckpointFailed", {phase="save"})
        end
        local machineryAborted, machineryReason =
            target.deps.machinery.abortLifecycle("save")
        if machineryAborted == nil then
            diagnose(machineryReason or "machineryCheckpointFailed", {phase="save"})
        end
        local economicsAborted, economicsReason =
            target.deps.economics.abortLifecycle("save")
        if economicsAborted == nil then
            diagnose(economicsReason or "economicsCheckpointFailed", {phase="save"})
        end
        local closed, checkpointReason = target.deps.coordinator.checkpoint(
            target.coordinator, "save", missionTime())
        if closed == nil then
            local failureReason = checkpointReason or "checkpointFailed"
            diagnose(failureReason, {phase = "save"})
            local preserved = stagePreviousLedger(target, failureReason)
            if preserved == nil then
            log("error", string.format(
                "open sessions could not be checkpointed (%s) and no previous FPL ledger could be preserved",
                failureReason))
                return nil, failureReason
            end
        log("error", string.format(
            "open sessions could not be checkpointed (%s); previous valid FPL ledger prepared for preservation",
            failureReason))
            return true
        end
    end
    local staged, saveReason, saveStatus = target.store:stage(target.ledger)
    if staged == nil then
        diagnose(saveReason or "ledgerSaveFailed", {phase = "save"})
        local failureReason = saveReason or "ledgerSaveFailed"
        local preserved = stagePreviousLedger(target, failureReason)
        if preserved == nil then
            log("error", string.format(
                "ledger save preparation failed (%s) and no previous FPL ledger could be preserved",
                failureReason))
            return nil, failureReason
        end
        log("error", string.format(
            "new ledger save preparation failed (%s); previous valid FPL ledger prepared for preservation",
            failureReason))
        return true
    end
    saveStatus.newLedgerSaved = true
    target.lastSaveStatus = saveStatus
    target.savePrepared = true
    if (saveStatus.capacityCompactedCycles or 0) > 0 then
        log("warning", string.format(
            "ledger checkpoint prepared after compacting %d closed cycle(s) for capacity",
            saveStatus.capacityCompactedCycles))
    else
        log("info", "ledger checkpoint prepared")
    end
    return true
end

local function publishLedger(missionInfo)
    local target = state or pendingSaveState
    if target == nil or target.savePrepared ~= true then
        return nil, "ledgerSaveNotPrepared"
    end
    local directory = savegameDirectory(missionInfo)
    if type(directory) ~= "string" then
        diagnose("savegameDirectoryUnavailable", {phase = "publish"})
        setSaveFailure(target, "savegameDirectoryUnavailable")
        log("error", "FPL ledger publication failed: savegame directory unavailable")
        return nil, "savegameDirectoryUnavailable"
    end
    local targetPort = nil
    if directory ~= target.savegameDirectory then
        local portReason
        targetPort, portReason = target.deps.filePort.new(directory)
        if targetPort == nil then
            local failureReason = portReason or "filePortUnavailable"
            diagnose(failureReason, {phase = "publish"})
            setSaveFailure(target, failureReason)
            log("error", "FPL ledger publication failed: target savegame storage unavailable")
            return nil, failureReason
        end
    end
    local saved, saveReason, saveStatus =
        target.store:publishStagedTo(targetPort)
    if saved == nil then
        diagnose(saveReason or "ledgerSaveFailed", {phase = "publish"})
        setSaveFailure(target, saveReason or "ledgerSaveFailed")
        log("error", "FPL ledger publication failed; the gameplay save may omit FPL data")
        return nil, saveReason or "ledgerSaveFailed"
    end
    local stagedStatus = target.lastSaveStatus
    saveStatus.capacityCompactedCycles = stagedStatus ~= nil
        and stagedStatus.capacityCompactedCycles or 0
    if stagedStatus ~= nil and stagedStatus.preservedPrevious == true then
        saveStatus.failureReason = stagedStatus.failureReason
        saveStatus.newLedgerSaved = false
        saveStatus.preservedPrevious = true
        saveStatus.state = "preservedPrevious"
    else
        saveStatus.newLedgerSaved = true
    end
    target.lastSaveStatus = saveStatus
    target.savePrepared = false
    if rawequal(target, pendingSaveState) then pendingSaveState = nil end
    if saveStatus.preservedPrevious == true then
        log("warning", "previous FPL ledger preserved; new FPL history was not saved")
    else
        log("info", "ledger saved")
    end
    return true
end

function SinglePlayerRuntime:saveToXMLFile(missionInfo)
    local target = state or pendingSaveState
    if target == nil then return end
    if target.saveInProgress then
        diagnose("ledgerSaveReentry", {phase = "save"})
        return nil, "ledgerSaveReentry"
    end
    target.saveInProgress = true
    -- The transactional store is permanently bound to the validated mission
    -- directory selected at loadMap. Callback arguments are not path authority.
    local ok, saved, reason = pcall(stageLedger)
    target.saveInProgress = false
    if not ok then
        setSaveFailure(target, "ledgerSaveFailed")
        diagnose("ledgerSaveFailed", {phase = "save"})
        log("error", "FPL ledger preparation threw; the gameplay save may omit FPL data")
        return nil, "ledgerSaveFailed"
    end
    return saved, reason
end

function SinglePlayerRuntime:publishSaveToXMLFile(missionInfo)
    local target = state or pendingSaveState
    if target == nil then return end
    if target.savePrepared ~= true then
        local prepared, prepareReason = self:saveToXMLFile()
        if prepared == nil then return nil, prepareReason end
        target = state or pendingSaveState
    end
    if target == nil then return nil, "ledgerSaveNotPrepared" end
    if target.publishInProgress then
        diagnose("ledgerSaveReentry", {phase = "publish"})
        return nil, "ledgerSaveReentry"
    end
    target.publishInProgress = true
    local ok, saved, reason = pcall(publishLedger, missionInfo)
    target.publishInProgress = false
    if not ok then
        setSaveFailure(target, "ledgerSaveFailed")
        diagnose("ledgerSaveFailed", {phase = "publish"})
        log("error", "FPL ledger publication threw; the gameplay save may omit FPL data")
        return nil, "ledgerSaveFailed"
    end
    return saved, reason
end

function SinglePlayerRuntime:deleteMap()
    local unloadingState = state
    deactivate("unload")
    if unloadingState ~= nil then pendingSaveState = unloadingState end
    diagnostics = {}
end

function SinglePlayerRuntime.getStatus()
    local guiStatus = state ~= nil and state.deps.guiController.getStatus() or {}
    local applicationStatus = state ~= nil
        and state.deps.application.getStatus() or {}
    local harvestStatus = state ~= nil
        and state.deps.harvest.getStatus() or {}
    local machineryStatus = state ~= nil
        and state.deps.machinery.getStatus() or {}
    local economicsStatus = state ~= nil
        and state.deps.economics.getStatus() or {}
    return {
        active = state ~= nil,
        diagnostics = SinglePlayerRuntime.getDiagnostics(),
        loadState = state ~= nil and state.loadStatus.state or nil,
        saveState = state ~= nil and state.lastSaveStatus ~= nil
            and state.lastSaveStatus.state or nil,
        saveEncodedBytes = state ~= nil and state.lastSaveStatus ~= nil
            and state.lastSaveStatus.encodedBytes or nil,
        saveFailureReason = state ~= nil and state.lastSaveStatus ~= nil
            and state.lastSaveStatus.failureReason or nil,
        capacityCompactedCycles =
            state ~= nil and state.lastSaveStatus ~= nil
            and state.lastSaveStatus.capacityCompactedCycles or 0,
        newLedgerSaved = state ~= nil and state.lastSaveStatus ~= nil
            and state.lastSaveStatus.newLedgerSaved or nil,
        guiActive = guiStatus.active == true,
        applicationActive = applicationStatus.active == true,
        applicationDisabled = applicationStatus.disabled == true,
        harvestActive = harvestStatus.active == true,
        harvestDisabled = harvestStatus.disabled == true,
        machineryActive = machineryStatus.active == true,
        machineryDisabled = machineryStatus.disabled == true,
        economicsActive = economicsStatus.active == true,
        exportAvailable = guiStatus.active == true and guiStatus.exportReason == nil
    }
end

function SinglePlayerRuntime.closeCycle(cycleId, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local activeState = state
    if activeState == nil then return nil, "runtimeInactive" end
    local time = missionTime()
    local missionValue = mission()
    local environment = type(missionValue) == "table"
        and rawget(missionValue, "environment") or nil
    local period = type(environment) == "table"
        and rawget(environment, "currentPeriod") or nil
    if type(cycleId) ~= "string" or type(time) ~= "number"
        or type(period) ~= "number" then
        return nil, "cycleCloseContextUnavailable"
    end
local result, reason = activeState.deps.coordinator.closeCycles(
activeState.coordinator, {
cycleIds={cycleId}, missionTime=time, period=period,
reason="manualCycleClose"
})
if result == nil then return nil, reason end
return result.closedCycles[1]
end

function SinglePlayerRuntime.listLegacyClosureCandidates(options, ...)
if select("#", ...) ~= 0 then
return nil, "unexpectedArgument"
end
local activeState = state
if activeState == nil then
return nil, "runtimeInactive"
end
if options == nil then
options = {
limit = activeState.deps.constants.LIMITS.maxQueryRows,
offset = 0
}
elseif type(options) ~= "table" or getmetatable(options) ~= nil then
return nil, "invalidOptions"
end
return activeState.ledger:listLegacyClosureCandidates(options)
end

function SinglePlayerRuntime.closeReviewedLegacyCycles(selections, ...)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end
    local activeState = state
    if activeState == nil then
        return nil, "runtimeInactive"
    end
    if type(selections) ~= "table" or getmetatable(selections) ~= nil
        or #selections == 0
        or #selections > activeState.deps.constants.LIMITS.maxQueryRows then
        return nil, "invalidLegacyClosureSelection"
    end
    local selected = {}
    local cycleIds = {}
    for index, selection in ipairs(selections) do
        if type(selection) ~= "table" or getmetatable(selection) ~= nil then
            return nil, "invalidLegacyClosureSelection"
        end
        for key in pairs(selection) do
            if key ~= "cycleId" and key ~= "reviewSnapshot" then
                return nil, "invalidLegacyClosureSelection"
            end
        end
        local cycleId = selection.cycleId
        local reviewSnapshot = selection.reviewSnapshot
        if type(reviewSnapshot) ~= "table"
            or getmetatable(reviewSnapshot) ~= nil then
            return nil, "invalidLegacyClosureSelection"
        end
        for key in pairs(reviewSnapshot) do
            if key ~= "revision"
                and key ~= "lastHarvestRecordId"
                and key ~= "lastHarvestMissionTime"
                and key ~= "lastActivityMissionTime" then
                return nil, "invalidLegacyClosureSelection"
            end
        end
        local reviewRevision = reviewSnapshot.revision
        local lastHarvestMissionTime =
            reviewSnapshot.lastHarvestMissionTime
        local lastActivityMissionTime =
            reviewSnapshot.lastActivityMissionTime
        if type(cycleId) ~= "string"
            or #cycleId == 0
            or #cycleId
                > activeState.deps.constants.LIMITS.idBytes
            or type(reviewRevision) ~= "number"
            or reviewRevision ~= math.floor(reviewRevision)
            or reviewRevision < 0
            or reviewRevision
                > activeState.deps.constants.LIMITS.maxIdentifier
            or type(reviewSnapshot.lastHarvestRecordId) ~= "string"
            or #reviewSnapshot.lastHarvestRecordId == 0
            or #reviewSnapshot.lastHarvestRecordId
                > activeState.deps.constants.LIMITS.idBytes
            or type(lastHarvestMissionTime) ~= "number"
            or lastHarvestMissionTime ~= lastHarvestMissionTime
            or lastHarvestMissionTime == math.huge
            or lastHarvestMissionTime == -math.huge
            or lastHarvestMissionTime < 0
            or lastHarvestMissionTime
                > activeState.deps.constants.LIMITS.maxMissionTime
            or type(lastActivityMissionTime) ~= "number"
            or lastActivityMissionTime ~= lastActivityMissionTime
            or lastActivityMissionTime == math.huge
            or lastActivityMissionTime == -math.huge
            or lastActivityMissionTime < 0
            or lastActivityMissionTime
                > activeState.deps.constants.LIMITS.maxMissionTime
            or selected[cycleId] ~= nil then
            return nil, "invalidLegacyClosureSelection"
        end
        selected[cycleId] = reviewSnapshot
        cycleIds[index] = cycleId
    end
local remaining = {}
local remainingCount = 0
for cycleId, reviewSnapshot in pairs(selected) do
remaining[cycleId] = reviewSnapshot
remainingCount = remainingCount + 1
end
local reviewOffset = 0
repeat
local reviewed, reviewReason =
SinglePlayerRuntime.listLegacyClosureCandidates({
limit=activeState.deps.constants.LIMITS.maxQueryRows,
offset=reviewOffset
})
if reviewed == nil then
return nil, reviewReason
end
for _, row in ipairs(reviewed.candidates) do
local reviewedCycleId = row.cycle.id
if remaining[reviewedCycleId] ~= nil then
local expected = remaining[reviewedCycleId]
local actual = row.reviewSnapshot
if type(actual) ~= "table"
or actual.revision ~= expected.revision
or actual.lastHarvestRecordId ~= expected.lastHarvestRecordId
or actual.lastHarvestMissionTime ~= expected.lastHarvestMissionTime
or actual.lastActivityMissionTime ~= expected.lastActivityMissionTime then
return nil, "legacyClosureSelectionChanged"
end
remaining[reviewedCycleId] = nil
remainingCount = remainingCount - 1
end
end
reviewOffset = reviewed.page.nextOffset
until remainingCount == 0 or reviewOffset == nil
if remainingCount ~= 0 then
return nil, "legacyClosureSelectionNotReviewed"
end
    local time = missionTime()
    local missionValue = mission()
    local environment = type(missionValue) == "table"
        and rawget(missionValue, "environment") or nil
    local period = type(environment) == "table"
        and rawget(environment, "currentPeriod") or nil
    local year = type(environment) == "table"
        and rawget(environment, "currentYear") or nil
    if type(year) ~= "number" then
        year = nil
    end
    if type(time) ~= "number" or type(period) ~= "number" then
        return nil, "cycleCloseContextUnavailable"
    end
local result, closeReason = activeState.deps.coordinator.closeCycles(
activeState.coordinator, {
cycleIds = cycleIds,
missionTime = time,
period = period,
        year = year,
        reason = "reviewedLegacyBulkClose"
    })
if result == nil then
return nil, closeReason
end
return {
closedCycles = result.closedCycles,
closedSessions = result.closedSessions,
requestedCount = #cycleIds
}
end

function SinglePlayerRuntime.getDiagnostics()
    local result = {}
    for index, row in ipairs(diagnostics) do
        local context = {}
        for key, value in pairs(row.context) do context[key] = value end
        result[index] = {code = row.code, context = context}
    end
    return result
end

function SinglePlayerRuntime.getMissionTime()
    if state == nil then return nil, "runtimeInactive" end
    return missionTime()
end

function SinglePlayerRuntime.listCycles(options)
    if state == nil then return nil, "runtimeInactive" end
    return state.ledger:listCycles(options or {})
end

function SinglePlayerRuntime.queryCycle(cycleId, options)
    if state == nil then return nil, "runtimeInactive" end
    return state.ledger:queryCycle(cycleId, options or {})
end

function SinglePlayerRuntime.install()
    if installed then return true, false end
    if type(_G.addModEventListener) ~= "function" then
        return nil, "modEventListenerUnavailable"
    end
    local utils = _G.Utils
    if type(utils) ~= "table"
        or type(rawget(utils, "prependedFunction")) ~= "function"
        or type(rawget(utils, "appendedFunction")) ~= "function" then
        return nil, "saveLifecycleUnavailable"
    end
    addModEventListener(SinglePlayerRuntime)
    installed = true
    return true, true
end

FieldProfitabilityLedger.Runtime.SinglePlayerRuntime = SinglePlayerRuntime
return SinglePlayerRuntime
