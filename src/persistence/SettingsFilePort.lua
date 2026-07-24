-- Fixed client-local presentation-settings path below the FPL modSettings tree.

FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Persistence = FieldProfitabilityLedger.Persistence or {}

local SettingsFilePort = {}
SettingsFilePort.__index = SettingsFilePort

local FILENAME = "fieldProfitabilityLedgerSettings.dat"
local XML_ROOT = "fieldProfitabilityLedgerSettings"

local function join(root, suffix)
    local last = string.sub(root, -1)
    if last == "/" or last == "\\" then return root .. suffix end
    return root .. "/" .. suffix
end

local function defaultIo(targetPath)
    local xmlClass = _G.XMLFile
    local exists = _G.fileExists
    local createDirectory = _G.createFolder
    if type(xmlClass) ~= "table" or type(xmlClass.create) ~= "function"
        or type(xmlClass.load) ~= "function" or type(exists) ~= "function"
        or type(createDirectory) ~= "function" then
        return nil
    end
    local candidatePath = targetPath .. ".candidate"
    local candidateBytes = nil

    local function closeXml(xml)
        if type(xml) == "table" and type(xml.delete) == "function" then
            pcall(xml.delete, xml)
        end
    end

    local function readXml()
        local existsOk, present = pcall(exists, targetPath)
        if not existsOk or present ~= true then return nil end
        local loadOk, xml = pcall(xmlClass.load, "fplSettingsRead", targetPath)
        if not loadOk or type(xml) ~= "table"
            or type(xml.getString) ~= "function" then
            closeXml(xml)
            return nil
        end
        local readOk, value = pcall(
            xml.getString, xml, XML_ROOT .. "#payload")
        closeXml(xml)
        return readOk and type(value) == "string" and value or nil
    end

    local function writeXml(bytes)
        local createOk, xml = pcall(
            xmlClass.create, "fplSettingsWrite", targetPath, XML_ROOT)
        if not createOk or type(xml) ~= "table"
            or type(xml.setString) ~= "function" or type(xml.save) ~= "function" then
            closeXml(xml)
            return nil, "settingsXmlCreateFailed"
        end
        local setOk = pcall(
            xml.setString, xml, XML_ROOT .. "#payload", bytes)
        local saveOk, saved = false, nil
        if setOk then saveOk, saved = pcall(xml.save, xml) end
        closeXml(xml)
        local existsOk, present = pcall(exists, targetPath)
        if not setOk or not saveOk or saved == false
            or not existsOk or present ~= true then
            return nil, "settingsXmlSaveFailed"
        end
        return true
    end

    return {
        createFolder = createDirectory,
        open = function(path, mode)
            if path == targetPath and mode == "rb" then
                local value = readXml()
                if value == nil then return nil, "notFound" end
                return {
                    read = function() return value end,
                    close = function() return true end
                }
            end
            if path ~= candidatePath or mode ~= "wb" then
                return nil, "invalidPath"
            end
            local chunks = {}
            return {
                write = function(_, value)
                    if type(value) ~= "string" then return nil, "invalidBytes" end
                    chunks[#chunks + 1] = value
                    return true
                end,
                close = function()
                    candidateBytes = table.concat(chunks)
                    return true
                end
            }
        end,
        rename = function(source, target)
            if source ~= candidatePath or target ~= targetPath
                or candidateBytes == nil then return nil, "invalidPath" end
            local saved, reason = writeXml(candidateBytes)
            if saved == true then candidateBytes = nil end
            return saved, reason
        end,
        remove = function(path)
            if path == candidatePath then candidateBytes = nil return true end
            if path == targetPath then return true end
            return nil, "invalidPath"
        end
    }
end

function SettingsFilePort.new(profileRoot, injected)
    if type(profileRoot) ~= "string" or #profileRoot == 0
        or string.find(profileRoot, "\0", 1, true) ~= nil then
        return nil, "profileRootUnavailable"
    end
    local settings = join(profileRoot, "modSettings")
    local directory = join(settings, "FS25_FieldProfitabilityLedger")
    local pathValue = join(directory, FILENAME)
    local operations = injected or defaultIo(pathValue)
    if type(operations) ~= "table"
        or type(operations.createFolder) ~= "function"
        or type(operations.open) ~= "function"
        or type(operations.rename) ~= "function"
        or type(operations.remove) ~= "function" then
        return nil, "settingsIoUnavailable"
    end
    return setmetatable({
        operations = operations,
        directories = {settings, directory},
        pathValue = pathValue
    }, SettingsFilePort)
end

function SettingsFilePort:path()
    return self.pathValue
end

function SettingsFilePort:read()
    local handle = self.operations.open(self.pathValue, "rb")
    if handle == nil then return nil, "notFound" end
    local contents, reason = handle:read("*a")
    local closed = handle:close()
    if contents == nil or closed == nil or closed == false then
        return nil, reason or "settingsReadFailed"
    end
    return contents
end

function SettingsFilePort:write(contents)
    if type(contents) ~= "string" then return nil, "invalidSettingsContents" end
    for _, directory in ipairs(self.directories) do
        local ok = self.operations.createFolder(directory)
        if ok == false then return nil, "settingsDirectoryUnavailable" end
    end
    local candidate = self.pathValue .. ".candidate"
    local handle, openReason = self.operations.open(candidate, "wb")
    if handle == nil then return nil, openReason or "settingsOpenFailed" end
    local wrote, writeReason = handle:write(contents)
    local closed, closeReason = handle:close()
    if wrote == nil or closed == nil or closed == false then
        self.operations.remove(candidate)
        return nil, writeReason or closeReason or "settingsWriteFailed"
    end
    self.operations.remove(self.pathValue)
    local renamed, renameReason = self.operations.rename(candidate, self.pathValue)
    if renamed == nil or renamed == false then
        self.operations.remove(candidate)
        return nil, renameReason or "settingsPublishFailed"
    end
    return {path = self.pathValue, bytes = #contents}
end

FieldProfitabilityLedger.Persistence.SettingsFilePort = SettingsFilePort
return SettingsFilePort
