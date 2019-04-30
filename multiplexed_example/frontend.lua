#!/usr/bin/env tarantool

local buffer = require('buffer')
local msgpack = require('msgpack')
local net_box = require('net.box')
local key_def = require('key_def')
local merger = require('merger')
local yaml = require('yaml')

-- Give buffer, nil, buffer, nil, etc. Stops after param.remaining
-- iterations.
local function reusable_source_gen(param)
    local remaining = param.remaining
    local buf = param.buffer

    -- Final stop.
    if remaining == 0 then
        return
    end

    param.remaining = remaining - 1

    -- Report end of an iteration.
    if remaining % 2 == 0 then
        return
    end

    -- Give a buffer.
    return box.NULL, buf
end

-- Fetch a data into a buffer, skip headers, wrap it into merger
-- source object.
local function fetch_data(conn, requests)
    local buf = buffer.ibuf()
    conn:call('batch_select', {requests}, {buffer = buf, skip_header = true})

    -- Skip an array around a call return values.
    local len
    len, buf.rpos = msgpack.decode_array_header(buf.rpos, buf:size())
    assert(len == 1)

    -- Skip an array around results (each of them is a tuple of
    -- tables).
    len, buf.rpos = msgpack.decode_array_header(buf.rpos, buf:size())
    assert(len == #requests)

    -- We cannot use merger.new_source_frombuffer(buf) here,
    -- because we need to report end-of-tuples, but return tuples
    -- from a next request on the next call to a gen function.
    return merger.new_buffer_source(reusable_source_gen, {buffer = buf,
        remaining = 2 * #requests - 1})
end

local conns = {
    net_box.connect('localhost:3301', {reconnect_after = 0.1}),
    net_box.connect('localhost:3302', {reconnect_after = 0.1}),
}

-- We lean on the fact that primary keys of all that spaces are
-- the same. Otherwise we would need to use different merger
-- context for each merge.
local key_parts = conns[1].space.a.index.pk.parts
local ctx = merger.context.new(key_def.new(key_parts))

-- The idea modelled here is that we have requests for several
-- spaces and acquire results in one net.box call.
local requests = {'a', 'b', 'c', 'd', 'e'}

local sources = {}
for i, conn in ipairs(conns) do
    sources[i] = fetch_data(conn, requests)
end

local res = {}
for _ = 1, #requests do
    -- Merge ith result from each storage. On the first step they
    -- are results from space 'a', one the second from 'b', etc.
    local tuples = merger.new(ctx, sources):select()
    table.insert(res, tuples)
end

print(yaml.encode(res))
os.exit()
