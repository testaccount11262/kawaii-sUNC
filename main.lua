--[[
	Kawaii-sUNC entry point:

		loadstring(game:HttpGet("https://raw.githubusercontent.com/Kaiddd/kawaii-sUNC/main/main.lua"))()

	An alternative `fetchSource(path) -> source` function may be passed as the first argument
	(e.g. for offline runs); by default modules are fetched from the GitHub repository.
	All modules are downloaded concurrently, then compiled in a fixed order: metadata, the test
	factories, program, runtime.
]]

local BASE_URL = "https://raw.githubusercontent.com/Kaiddd/kawaii-sUNC/main/"
local MAX_CONCURRENT_DOWNLOADS = 16

local fetchSource = (...) or function(path)
	return game:HttpGet(BASE_URL .. path)
end

-- Test modules, in the order the program runs them.
local TEST_NAMES = {
	"cache.invalidate",
	"cache.iscached",
	"cache.replace",
	"getcallbackvalue",
	"getscriptclosure",
	"cloneref",
	"compareinstances",
	"getrenv",
	"firesignal",
	"base64encode",
	"base64decode",
	"lz4compress",
	"lz4decompress",
	"getgc",
	"getgenv",
	"getloadedmodules",
	"setrawmetatable",
	"getrunningscripts",
	"getscripts",
	"getscriptfromthread",
	"getsenv",
	"debug.getproto",
	"debug.getconstant",
	"debug.getupvalue",
	"debug.setupvalue",
	"debug.getprotos",
	"debug.getupvalues",
	"debug.getstack",
	"debug.getinfo",
	"debug.getconstants",
	"debug.setconstant",
	"getfunctionhash",
	"filtergc",
	"replicatesignal",
	"hookfunction",
	"clonefunction",
	"restorefunction",
	"iscclosure",
	"isexecutorclosure",
	"firetouchinterest",
	"islclosure",
	"newcclosure",
	"getscripthash",
	"setreadonly",
	"request",
	"fireclickdetector",
	"fireproximityprompt",
	"getconnections",
	"gethiddenproperty",
	"sethiddenproperty",
	"getinstances",
	"getnilinstances",
	"setscriptable",
	"isscriptable",
	"isreadonly",
	"setthreadidentity",
	"getthreadidentity",
	"gethui",
	"getscriptbytecode",
	"getcustomasset",
	"WebSocket.connect",
	"isrenderobj",
	"isrenderobj-2",
	"getrenderproperty",
	"Drawing.new",
	"identifyexecutor",
}

local function testPath(name)
	return "src/tests/" .. name .. ".lua"
end

local modulePaths = { "src/metadata.lua" }
for _, name in ipairs(TEST_NAMES) do
	table.insert(modulePaths, testPath(name))
end
table.insert(modulePaths, "src/program.lua")
table.insert(modulePaths, "src/runtime.lua")

-- Download every module up front; one request at a time took most of the start-up time.
local downloads = {} -- path -> { ok, sourceOrError }
local nextDownload = 1
local workerCount = math.min(MAX_CONCURRENT_DOWNLOADS, #modulePaths)
local finishedWorkers = 0

local MAX_RETRIES = 3 -- 최대 재시도 횟수 설정

local function downloadWorker()
    while nextDownload <= #modulePaths do
        local path = modulePaths[nextDownload]
        nextDownload += 1
        
        local success, ok, sourceOrError
        local attempts = 0
        local isDownloadedValid = false
        
        -- 다운로드가 성공하고 유효한 소스가 올 때까지 또는 최대 재시도 횟수에 도달할 때까지 반복
        repeat
            attempts += 1
            if attempts > 1 then
                print(string.format("[다운로드 재시도 %d/%d] 경로: %s", attempts, MAX_RETRIES, path))
            else
                print(string.format("[다운로드 시작] 경로: %s", path))
            end
            
            success, ok, sourceOrError = pcall(fetchSource, path)
            
            -- [핵심 수정] pcall 성공 여부 뿐만 아니라, 반환된 소스가 유효한 문자열인지 검증
            -- (fetchSource가 ok, sourceOrError 형태를 반환하는지, 혹은 sourceOrError 단독으로 문자열을 반환하는지에 따라 조정)
            local actualSource = sourceOrError or ok
            
            if not success or type(actualSource) ~= "string" or #actualSource == 0 then
                local errReason = not success and tostring(ok) or "Source is nil or empty"
                warn(string.format("[다운로드 경고] 실패 (시도 %d/%d) - 경로: %s | 사유: %s", attempts, MAX_RETRIES, path, errReason))
                
                if attempts < MAX_RETRIES then
                    task.wait(1) -- 재시도 전 잠시 대기
                end
            else
                isDownloadedValid = true
                print(string.format("[다운로드 성공] 경로: %s (소스 길이: %d bytes)", path, #actualSource))
                -- 올바른 형식으로 저장 (fetchSource 구조에 맞게 조정)
                downloads[path] = { true, actualSource }
                break
            end
        until attempts >= MAX_RETRIES

        -- 최종 실패 처리
        if not isDownloadedValid then
            local errMessage = "Max retries exceeded or invalid source returned"
            warn(string.format("[다운로드 최종 실패] 경로: %s | 사유: %s", path, errMessage))
            downloads[path] = { false, errMessage }
        end
    end
    finishedWorkers += 1
end

for _ = 1, workerCount do
    task.spawn(downloadWorker)
end

while finishedWorkers < workerCount do
    task.wait()
end
print("[모든 모듈 다운로드 작업 완료]")

local function loadModule(path)
	local ok, source = table.unpack(downloads[path])
	if not ok then
		error(source, 0)
	end
	local chunk, err = loadstring(source, "@" .. path)
	return assert(chunk, err)
end

local metadata = loadModule("src/metadata.lua")()

local testFactories = {}
for _, name in ipairs(TEST_NAMES) do
	testFactories[name] = loadModule(testPath(name))
end

metadata.__testFactories = testFactories
metadata.__programFactory = loadModule("src/program.lua")

return loadModule("src/runtime.lua")(metadata)
