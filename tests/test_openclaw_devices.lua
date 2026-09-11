package.path = "./luasrc/?.lua;./luasrc/?/?.lua;" .. package.path

local devices = require "openclaw.devices"

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected=" .. tostring(expected) .. " actual=" .. tostring(actual))
	end
end

local function decoder(text)
	if text:find('"missing"', 1, true) then return { paired = {} } end
	if text:find('"pending":"bad"', 1, true) then return { pending = "bad", paired = {} } end
	if text:find('"requestId":7', 1, true) then return { pending = { { requestId = 7, deviceId = "device_1" } }, paired = {} } end
	return {
		pending = { { requestId = "request_1", deviceId = "device_1" } },
		paired = {}
	}
end

local parsed, code = devices.parse_list('warning\n{"pending":[],"paired":[]}\n', decoder)
assert_equal(type(parsed), "table", "prefixed JSON should parse")
assert_equal(code, nil, "valid schema should not return an error")

local empty_array_marker = {}
assert_equal(devices.json_array({}, function(raw)
	assert_equal(raw, "[]", "empty array source")
	return empty_array_marker
end), empty_array_marker, "empty tables must use the JSON parser array marker")
assert_equal(devices.json_array(parsed.pending, decoder), parsed.pending, "non-empty arrays must be preserved")

parsed, code = devices.parse_list('{"missing":true}', decoder)
assert_equal(parsed, nil, "missing pending must fail")
assert_equal(code, "DEVICES_SCHEMA_MISMATCH", "missing pending error code")

parsed, code = devices.parse_list('{"pending":"bad","paired":[]}', decoder)
assert_equal(parsed, nil, "non-array pending must fail")
assert_equal(code, "DEVICES_SCHEMA_MISMATCH", "non-array pending error code")

parsed, code = devices.parse_list('{"pending":[{"requestId":7}],"paired":[]}', decoder)
assert_equal(parsed, nil, "numeric requestId must fail")
assert_equal(code, "DEVICES_SCHEMA_MISMATCH", "requestId type error code")

local before = { requestId = "request_1", deviceId = "device_1" }
local status, error_code = devices.evaluate_approval(1, before, nil, nil, "Error: request was not approved")
assert_equal(status, "error", "non-zero approve must fail even when output contains approved")
assert_equal(error_code, "APPROVAL_CLI_FAILED", "non-zero approve error code")

status, error_code = devices.evaluate_approval(0, before, { pending = {}, paired = { { deviceId = "device_1" } } }, nil, "Approved")
assert_equal(status, "ok", "paired deviceId must confirm approval")
assert_equal(error_code, nil, "confirmed approval has no error code")

status, error_code = devices.evaluate_approval(0, before, { pending = { before }, paired = {} }, nil, "Approved")
assert_equal(status, "error", "request remaining pending must fail")
assert_equal(error_code, "APPROVAL_NOT_APPLIED", "not-applied error code")

status, error_code = devices.evaluate_approval(0, before, { pending = {}, paired = {} }, nil, "Approved")
assert_equal(status, "unconfirmed", "disappeared request without paired device must remain unconfirmed")
assert_equal(error_code, "APPROVAL_UNCONFIRMED", "unconfirmed error code")

local clean = devices.sanitize_output("token=secret\27[31m failed\27[0m", 300)
assert(not clean:find("secret", 1, true), "token value must be redacted")
assert(not clean:find("\27", 1, true), "ANSI sequence must be stripped")

print("ok")
