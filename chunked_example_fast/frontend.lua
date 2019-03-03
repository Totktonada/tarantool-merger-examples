#!/usr/bin/env tarantool

local buffer = require('buffer')
local msgpack = require('msgpack')
local vshard = require('vshard')
local key_def = require('key_def')
local merger = require('merger')
local json = require('json')
local yaml = require('yaml')
local vshard_cfg = require('vshard_cfg')

local merger_context_cache = {}

-- XXX: Implement some cache clean up strategy and a way to manual
-- cache purge.
local function get_merger_context(space_name, index_name)
    local merger_context

    -- Get from the cache if exists.
    if merger_context_cache[space_name] ~= nil then
        merger_context = merger_context_cache[space_name][index_name]
        if merger_context ~= nil then
            return merger_context
        end
    end

    -- Get requested and primary index metainfo.
    local conn = select(2, next(vshard.router.routeall())).master.conn
    local primary_index = conn.space[space_name].index[0]
    local index = conn.space[space_name].index[index_name]

    -- Create a key def.
    local key_def_inst = key_def.new(index.parts)
    if not index.unique then
        key_def_inst = key_def_inst:merge(key_def.new(primary_index.parts))
    end

    -- Create a merger context.
    merger_context = merger.context.new(key_def_inst)

    -- Write to the cache.
    if merger_context_cache[space_name] == nil then
        merger_context_cache[space_name] = {}
    end
    merger_context_cache[space_name][index_name] = merger_context

    return merger_context
end

local function decode_metainfo(buf)
    -- Skip an array around a call return values.
    local len
    len, buf.rpos = msgpack.decode_array(buf.rpos, buf:size())
    assert(len == 2)

    -- Decode a first return value (metainfo).
    local res
    res, buf.rpos = msgpack.decode(buf.rpos, buf:size())
    return res
end

--- Wait for a data chunk and request for the next data chunk.
local function fetch_chunk(context, state)
    local net_box_opts = context.net_box_opts
    local buf = context.buffer
    local call_args = context.call_args
    local replicaset = context.replicaset
    local future = state.future

    -- The source was entirely drained.
    if future == nil then
        return nil
    end

    -- Wait for requested data.
    local res, err = future:wait_result()
    if res == nil then
        error(err)
    end

    -- Decode metainfo, leave data to be processed by the merger.
    local cursor = decode_metainfo(buf)

    -- Check whether we need the next call.
    if cursor.is_end then
        local next_state = {}
        return next_state, buf
    end

    -- Request the next data while we processing the current ones.
    -- Note: We reuse the same buffer for all request to a replicaset.
    local next_call_args = call_args
    next_call_args[4].cursor = cursor -- change context.call_args too,
                                      -- but it does not matter
    local next_future = replicaset:callro('box_select_chunked', next_call_args,
        net_box_opts)

    local next_state = {future = next_future}
    return next_state, buf
end

local function mr_call(space_name, index_name, key, opts)
    local opts = opts or {}
    local merger_context = get_merger_context(space_name, index_name)
    local call_args = {space_name, index_name, key, opts}

    -- Request a first data chunk and create merger sources.
    local merger_sources = {}
    for _, replicaset in pairs(vshard.router.routeall()) do
        -- Perform a request.
        local buf = buffer.ibuf()
        local net_box_opts = {is_async = true, buffer = buf, skip_header = true}
        local future = replicaset:callro('box_select_chunked', call_args,
            net_box_opts)

        -- Create a source.
        local context = {
            net_box_opts = net_box_opts,
            buffer = buf,
            call_args = call_args,
            replicaset = replicaset,
        }
        local state = {future = future}
        local source = merger.new_buffer_source(fetch_chunk,
            context, state)
        table.insert(merger_sources, source)
    end

    local merger_inst = merger.new(merger_context, merger_sources)
    return merger_inst:select()
end

-- Initialize vshard router.
vshard.router.cfg(vshard_cfg.wait_cfg())
vshard.router.bootstrap()

-- Fill storages with data.
local tuples = {
    {1, 'one'},
    {2, 'two'},
    {3, 'three'},
    {4, 'four'},
    {5, 'five'},
    {6, 'six'},
    {7, 'seven'},
    {8, 'eight'},
    {9, 'nine'},
    {10, 'ten'},
    {11, 'eleven'},
    {12, 'twelve'},
    {13, 'thirteen'},
    {14, 'fourteen'},
    {15, 'fifteen'},
    {16, 'sixteen'},
    {17, 'seventeen'},
    {18, 'eighteen'},
    {19, 'nineteen'},
    {20, 'twenty'},
}

for _, tuple in ipairs(tuples) do
    local bucket_id = vshard.router.bucket_id(tuple[1])
    local res, err = vshard.router.callrw(bucket_id, 'box_insert', {'s', tuple})
    if res == nil then error(err) end
end

-- Show data on storages.
print('')
print('Storages')
print('========')
for _, replicaset in pairs(vshard.router.routeall()) do
    print('')
    print(replicaset.master.name)
    print('---------')
    local res, err = replicaset:callro('box_select', {'s'})
    if res == nil then error(err) end
    for _, tuple in ipairs(res) do
        print(json.encode(tuple))
    end
end

-- Perform merge call.
print('')
print('mr_call')
print('=======')
local res = mr_call('s', 'pk', {})
print(yaml.encode(res))
os.exit()
