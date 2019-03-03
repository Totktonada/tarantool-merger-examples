#!/usr/bin/env tarantool

local buffer = require('buffer')
local net_box = require('net.box')
local key_def = require('key_def')
local merger = require('merger')
local yaml = require('yaml')

local BLOCK_SIZE = 2

local function fetch_chunk(param, state)
    local conn = param.conn
    local key_def_inst = param.key_def
    local last_tuple = state.last_tuple

    local opts = {limit = BLOCK_SIZE}
    local res

    if state.last_tuple == nil then
        -- A first request: ALL iterator + limit.
        res = conn.space.s:select(nil, opts)
    else
        -- Subsequent requests: GT iterator + limit.
        local key = key_def_inst:extract_key(last_tuple)
        opts.iterator = box.index.GT
        res = conn.space.s:select(key, opts)
    end

    if #res == 0 then return nil end

    local new_state = {conn = conn, last_tuple = res[#res]}
    return new_state, res
end

local conns = {
    net_box.connect('localhost:3301', {reconnect_after = 0.1}),
    net_box.connect('localhost:3302', {reconnect_after = 0.1}),
}

local key_parts = conns[1].space.s.index.pk.parts
local key_def_inst = key_def.new(key_parts)
local ctx = merger.context.new(key_def_inst)
local sources = {}
for i, conn in ipairs(conns) do
    local param = {conn = conns[i], key_def = key_def_inst}
    sources[i] = merger.new_table_source(fetch_chunk, param, {})
end
local merger_inst = merger.new(ctx, sources)
local res = merger_inst:select()
print(yaml.encode(res))
os.exit()
