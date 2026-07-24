-- Graphical-client lifecycle for the Field Profitability Ledger menu page.

FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Gui = FieldProfitabilityLedger.Gui or {}

local GuiController = {}
local frame = nil
local menu = nil
local pageRegistered = false
local actionEventId = nil
local inputRefreshHookInstalled = false
local active = false
local lastStatus = {}
local MOD_DIRECTORY = g_currentModDirectory or ""
local PAGE_CONTROL_NAME = "fplFieldProfitabilityLedgerPageController"

local function dependencies()
    local namespace = rawget(_G, "FieldProfitabilityLedger")
    local services = type(namespace) == "table" and rawget(namespace, "Services") or nil
    local persistence = type(namespace) == "table" and rawget(namespace, "Persistence") or nil
    local export = type(namespace) == "table" and rawget(namespace, "Export") or nil
    local gui = type(namespace) == "table" and rawget(namespace, "Gui") or nil
    local report = type(services) == "table" and rawget(services, "ReportService") or nil
    local clientSettings = type(services) == "table" and rawget(services, "ClientSettings") or nil
    local ledgerCommands = type(services) == "table" and rawget(services, "LedgerCommands") or nil
    local settingsPort = type(persistence) == "table" and rawget(persistence, "SettingsFilePort") or nil
    local exportPort = type(persistence) == "table" and rawget(persistence, "ExportFilePort") or nil
    local exportService = type(export) == "table" and rawget(export, "ExportService") or nil
    local ledgerFrame = type(gui) == "table" and rawget(gui, "LedgerFrame") or nil
    if type(report) ~= "table" or type(report.new) ~= "function"
        or type(clientSettings) ~= "table" or type(clientSettings.new) ~= "function"
        or type(ledgerCommands) ~= "table" or type(ledgerCommands.new) ~= "function"
        or type(settingsPort) ~= "table" or type(settingsPort.new) ~= "function"
        or type(exportPort) ~= "table" or type(exportPort.new) ~= "function"
        or type(exportService) ~= "table" or type(exportService.new) ~= "function"
        or type(ledgerFrame) ~= "table" or type(ledgerFrame.new) ~= "function" then
        return nil, "guiDependencyUnavailable"
    end
    return {
        report=report, clientSettings=clientSettings, ledgerCommands=ledgerCommands,
        settingsPort=settingsPort, exportPort=exportPort,
        exportService=exportService, ledgerFrame=ledgerFrame
    }
end

local function profileRoot()
    local getter = _G.getUserProfileAppPath
    if type(getter) ~= "function" then return nil end
    local ok, value = pcall(getter)
    return ok and type(value) == "string" and value or nil
end

local function filename(relative)
    local base = MOD_DIRECTORY
    local utils = _G.Utils
    if type(utils) == "table" and type(utils.getFilename) == "function" then
        return utils.getFilename(relative, base)
    end
    return base .. relative
end

local function inGameMenu()
    local gui = _G.g_gui
    local class = _G.InGameMenu
    local controllers = type(gui) == "table" and rawget(gui, "screenControllers") or nil
    local result = type(controllers) == "table" and controllers[class] or nil
    if result ~= nil then return result end
    local mission = _G.g_currentMission
    return type(mission) == "table" and rawget(mission, "inGameMenu") or nil
end

local function createSettings(deps)
    local root = profileRoot()
    if root == nil then return nil, "profileRootUnavailable" end
    local port, reason = deps.settingsPort.new(root)
    if port == nil then return nil, reason end
    local service
    service, reason = deps.clientSettings.new(port)
    if service == nil then return nil, reason end
    local _, loadStatus = service:load()
    return service, loadStatus
end

local function createExporter(deps, reportService)
    local root = profileRoot()
    if root == nil then return nil, "profileRootUnavailable" end
    local port, reason = deps.exportPort.new(root)
    if port == nil then return nil, reason end
    return deps.exportService.new(reportService, port)
end

local function registerPage(
        deps, reportService, exporter, settings, commands, runtimeStatusProvider)
    local gui = _G.g_gui
    if type(gui) ~= "table" or type(gui.loadGui) ~= "function" then
        return nil, "guiManagerUnavailable"
    end
    menu = inGameMenu()
    if type(menu) ~= "table" or type(menu.addPage) ~= "function" then
        return nil, "inGameMenuUnavailable"
    end
    if frame == nil then
        local reason
        frame, reason = deps.ledgerFrame.new(
            reportService, exporter, settings, commands, runtimeStatusProvider)
        if frame == nil then return nil, reason end
        local ok, loadReason = pcall(
            gui.loadGui, gui,
            filename("gui/FieldProfitabilityLedgerFrame.xml"),
            "fplFieldProfitabilityLedgerFrame", frame, true)
        if not ok then
            frame = nil
            return nil, "ledgerGuiLoadFailed:" .. tostring(loadReason)
        end
    else
        frame:setServices(
            reportService, exporter, settings, commands, runtimeStatusProvider)
    end
    if not pageRegistered then
        local paging = rawget(menu, "pagingElement")
        local guiUtils = _G.GuiUtils
        local predicate = function() return active end
        local icon = filename("icon_fieldProfitabilityLedgerTab.dds")
        -- GuiUtils.getUVs defaults to FS25's 1024 x 1024 coordinate space,
        -- independently of the source texture's pixel dimensions.  Requesting
        -- 512 here samples only the top-left quarter of a standalone texture.
        local uvs = {0, 0, 1024, 1024}
        local useDynamicPage = type(paging) == "table"
            and type(paging.addElement) == "function"
            and type(menu.registerPage) == "function"
            and type(menu.addPageTab) == "function"
            and type(guiUtils) == "table"
            and type(guiUtils.getUVs) == "function"
        local ok, reason
        if useDynamicPage then
            ok, reason = pcall(function()
                menu[PAGE_CONTROL_NAME] = frame
                paging:addElement(frame)
                menu:registerPage(frame, nil, predicate)
                menu:addPageTab(frame, icon, guiUtils.getUVs(uvs))
                if type(paging.updateAbsolutePosition) == "function" then
                    paging:updateAbsolutePosition()
                end
                if type(paging.updatePageMapping) == "function" then
                    paging:updatePageMapping()
                end
                if type(menu.rebuildTabList) == "function" then
                    menu:rebuildTabList()
                end
            end)
        else
            ok, reason = pcall(menu.addPage, menu, frame, nil,
                icon, uvs, predicate)
        end
        if not ok then return nil, "ledgerPageRegistrationFailed:" .. tostring(reason) end
        pageRegistered = true
    end
    if type(menu.setPageEnabled) == "function" then
        pcall(menu.setPageEnabled, menu, deps.ledgerFrame, true)
    end
    return true
end

local function currentMissionTime()
    local runtime = type(FieldProfitabilityLedger) == "table"
        and rawget(FieldProfitabilityLedger, "Runtime") or nil
    local singlePlayer = type(runtime) == "table"
        and rawget(runtime, "SinglePlayerRuntime") or nil
    local provider = type(singlePlayer) == "table"
        and rawget(singlePlayer, "getMissionTime") or nil
    if type(provider) == "function" then
        local ok, value = pcall(provider)
        if ok and type(value) == "number" and value == value
            and value ~= math.huge and value ~= -math.huge then
            return value
        end
    end
    local mission = _G.g_currentMission
    local value = type(mission) == "table" and rawget(mission, "time") or nil
    if type(value) ~= "number" or value ~= value
        or value == math.huge or value == -math.huge then
        return nil
    end
    return value
end

function GuiController.open()
    if not active or frame == nil or menu == nil then return nil, "guiInactive" end
    local gui = _G.g_gui
    if type(gui) ~= "table" or type(gui.showGui) ~= "function" then
        return nil, "guiManagerUnavailable"
    end
    gui:showGui("InGameMenu")
    local paging = rawget(menu, "pagingElement")
    local selector = rawget(menu, "pageSelector")
    if type(paging) ~= "table"
        or type(paging.getPageMappingIndexByElement) ~= "function"
        or type(selector) ~= "table" or type(selector.setState) ~= "function" then
        return nil, "menuPagingUnavailable"
    end
    local pageElement = frame
    local index = paging:getPageMappingIndexByElement(pageElement)
    if type(index) ~= "number" then
        local pageRoots = rawget(menu, "pageRoots")
        pageElement = type(pageRoots) == "table" and pageRoots[frame] or nil
        if pageElement == nil then
            local elements = rawget(frame, "elements")
            pageElement = type(elements) == "table" and elements[1] or nil
        end
        index = pageElement ~= nil
            and paging:getPageMappingIndexByElement(pageElement) or nil
    end
    if type(index) ~= "number" then return nil, "ledgerPageUnavailable" end
    if type(menu.goToPage) == "function" then
        menu:goToPage(pageElement, true)
    else
        selector:setState(index, true)
    end
    return true
end

local function registerInputAction()
    local binding = _G.g_inputBinding
    local actions = _G.InputAction
    local action = type(actions) == "table" and rawget(actions, "FPL_OPEN_LEDGER") or nil
    if type(binding) ~= "table" or type(binding.registerActionEvent) ~= "function"
        or action == nil then
        return nil, "inputActionUnavailable"
    end
    local _, eventId = binding:registerActionEvent(
        action, GuiController, function() GuiController.open() end,
        false, true, false, true)
    if eventId == nil then return nil, "inputActionRegistrationFailed" end
    actionEventId = eventId
    if type(binding.setActionEventText) == "function" then
        local i18n = _G.g_i18n
        local label = type(i18n) == "table" and type(i18n.getText) == "function"
            and i18n:getText("input_FPL_OPEN_LEDGER") or "Field Profitability Ledger"
        binding:setActionEventText(eventId, label)
    end
    if type(binding.setActionEventTextVisibility) == "function" then
        binding:setActionEventTextVisibility(eventId, true)
    end
    return true
end

local function removeInputAction()
    local binding = _G.g_inputBinding
    if actionEventId ~= nil and type(binding) == "table"
        and type(binding.removeActionEvent) == "function" then
        pcall(binding.removeActionEvent, binding, actionEventId)
    end
    actionEventId = nil
end

local function refreshInputAction()
    removeInputAction()
    return registerInputAction()
end

-- Map loading installs the FPL page before FS25 creates the player's global
-- action-event set.  FS25 rebuilds that set on entry to gameplay, so refresh
-- our early registration after the base player events have been registered.
local function installInputRefreshHook()
    if inputRefreshHookInstalled then return true end
    local component = _G.PlayerInputComponent
    local utils = _G.Utils
    local original = type(component) == "table"
        and rawget(component, "registerGlobalPlayerActionEvents") or nil
    if type(original) ~= "function" or type(utils) ~= "table"
        or type(utils.appendedFunction) ~= "function" then
        return false
    end
    component.registerGlobalPlayerActionEvents = utils.appendedFunction(
        original,
        function()
            if active then
                local registered, reason = refreshInputAction()
                lastStatus.actionReason = registered == nil and reason or nil
            end
        end)
    inputRefreshHookInstalled = true
    return true
end

function GuiController.install(ledger, runtimeStatusProvider, closeCycleProvider,
    legacyCandidateProvider, legacyCloseProvider, capacityCompactionProvider)
    if active then return true, false end
    if runtimeStatusProvider ~= nil
        and type(runtimeStatusProvider) ~= "function" then
        return nil, "invalidRuntimeStatusProvider"
    end
    if (closeCycleProvider ~= nil and type(closeCycleProvider) ~= "function")
        or (legacyCandidateProvider ~= nil
            and type(legacyCandidateProvider) ~= "function")
        or (legacyCloseProvider ~= nil
            and type(legacyCloseProvider) ~= "function")
        or (capacityCompactionProvider ~= nil
            and type(capacityCompactionProvider) ~= "function") then
        return nil, "invalidCycleCloseProvider"
    end
    local deps, reason = dependencies()
    if deps == nil then return nil, reason end
    local reportService
    reportService, reason = deps.report.new(ledger)
    if reportService == nil then return nil, reason end
    local commands
    commands, reason = deps.ledgerCommands.new(
        ledger, currentMissionTime, closeCycleProvider,
        legacyCandidateProvider, legacyCloseProvider,
        capacityCompactionProvider)
    if commands == nil then return nil, reason end
    local settings, settingsStatus = createSettings(deps)
    local exporter, exportReason = createExporter(deps, reportService)
    lastStatus = {
        settingsState=type(settingsStatus) == "table" and settingsStatus.state or nil,
        settingsReason=settings == nil and settingsStatus or nil,
        exportReason=exporter == nil and exportReason or nil
    }
    active = true
    local registered
    registered, reason = registerPage(
        deps, reportService, exporter, settings, commands, runtimeStatusProvider)
    if registered == nil then
        active = false
        return nil, reason
    end
    installInputRefreshHook()
    local inputRegistered
    inputRegistered, reason = registerInputAction()
    if inputRegistered == nil then
        GuiController.uninstall()
        return nil, reason
    end
    return true, true
end

function GuiController.uninstall()
    removeInputAction()
    active = false
    local deps = dependencies()
    if frame ~= nil then frame:deactivate() end
    if pageRegistered and menu ~= nil and deps ~= nil
        and type(menu.setPageEnabled) == "function" then
        pcall(menu.setPageEnabled, menu, deps.ledgerFrame, false)
    end
    lastStatus = {}
    return true
end

function GuiController.getStatus()
    return {
        active=active, pageRegistered=pageRegistered,
        actionRegistered=actionEventId ~= nil,
        settingsState=lastStatus.settingsState,
        settingsReason=lastStatus.settingsReason,
        exportReason=lastStatus.exportReason,
        actionReason=lastStatus.actionReason
    }
end

FieldProfitabilityLedger.Gui.GuiController = GuiController
return GuiController
