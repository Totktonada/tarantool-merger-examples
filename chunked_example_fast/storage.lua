#!/usr/bin/env tarantool

local fio = require('fio')
local key_def = require('key_def')
local vshard = require('vshard')
local vshard_cfg = require('vshard_cfg')

local function fio_write(filename, value)
    assert(type(value) == 'string')
    local fh = fio.open(filename, {'O_CREAT', 'O_TRUNC', 'O_WRONLY'})
    fh:write(value, #value)
    fh:close()
    fio.chmod(filename, tonumber('0755', 8))
end

local function merge_tables(...)
    local res = {}
    for i = 1, select('#', ...) do
        local t = select(i, ...)
        for k, v in pairs(t) do
            res[k] = v
        end
    end
    return res
end

local instance_name = fio.basename(arg[0], '.lua')
local box_cfg = {
    listen = instance_name == 'storage_1' and 3301 or 3302,
    wal_dir = instance_name,
    memtx_dir = instance_name,
    log = instance_name .. '.log',
    pid_file = instance_name .. '.pid',
    background = true,
}
box.cfg(box_cfg)

box.once('init_storage', function()
    box.schema.space.create('s')
    box.space.s:create_index('pk')
    box.schema.user.grant('guest', 'read,write', 'space', 's')

    box.schema.func.create('box_select')
    box.schema.func.create('box_insert')
    box.schema.func.create('box_select_chunked')

    box.schema.user.grant('guest', 'execute', 'function', 'box_select')
    box.schema.user.grant('guest', 'execute', 'function', 'box_insert')
    box.schema.user.grant('guest', 'execute', 'function', 'box_select_chunked')
end)

fio_write(instance_name .. '.instance.uuid', box.info.uuid)
fio_write(instance_name .. '.cluster.uuid', box.info.cluster.uuid)

-- Initialize vshard storage.
_G.vshard = vshard
local vshard_cfg_inst = merge_tables(vshard_cfg.wait_cfg(), box_cfg)
vshard.storage.cfg(vshard_cfg_inst, box.info.uuid)

-- Set to small value just to show everything work. Real block
-- size should be bigger.
local BLOCK_SIZE = 2

local iterator_types = {
    [box.index.EQ] = true,
    [box.index.REQ] = true,
    [box.index.ALL] = true,
    [box.index.LT] = true,
    [box.index.LE] = true,
    [box.index.GE] = true,
    [box.index.GT] = true,
}

local asc_iterator_types = {
    [box.index.EQ] = true,
    [box.index.ALL] = true,
    [box.index.GE] = true,
    [box.index.GT] = true,
}

local function check_iterator_type(opts, key)
    local key_is_nil = (key == nil or
        (type(key) == 'table' and #key == 0))
    local iterator_type = box.internal.check_iterator_type(opts, key_is_nil)
    if not iterator_types[iterator_type] then
        error('wrong iterator type')
    end
    return iterator_type
end

-- Example for unique indexes. Non-unique now requires much
-- more code. See also #3898.
local function make_cursor(index, opts, data)
    assert(index.unique)

    local last_tuple = data[#data]
    local next_key = key_def.new(index.parts):extract_key(last_tuple)
    local next_iterator

    if asc_iterator_types[opts.iterator] then
        next_iterator = box.index.GT
    else
        next_iterator = box.index.LT
    end

    local next_limit
    if opts.limit ~= nil then
        next_limit = opts.limit - BLOCK_SIZE
    end

    return {
        is_end = false,
        key = next_key,
        iterator = next_iterator,
        limit = next_limit,
    }
end

-- Helper to use box's :select() via call in vshard.
local function box_select_chunked(space_name, index_name, key, opts)
    local opts = opts or {}
    if opts.cursor ~= nil then
        assert(not opts.cursor.is_end)
        key = opts.cursor.key
        opts.iterator = opts.cursor.iterator
        opts.limit = opts.cursor.limit
        opts.offset = 0
    end

    local index = box.space[space_name].index[index_name]
    opts.iterator = check_iterator_type(opts, key)
    local real_limit = math.min(opts.limit or BLOCK_SIZE + 1, BLOCK_SIZE + 1)
    local data = index:select(key, {
        iterator = opts.iterator,
        limit = real_limit,
        offset = opts.offset,
    })

    local cursor
    if #data < real_limit then
        cursor = {is_end = true}
    else
        data[BLOCK_SIZE + 1] = nil
        cursor = make_cursor(index, opts, data)
    end

    return cursor, data
end

local function box_select(space_name)
    return box.space[space_name]:select()
end

local function box_insert(space_name, tuple)
    return box.space[space_name]:insert(tuple)
end

-- Expose functions to call it using net.box / vshard.
_G.box_select_chunked = box_select_chunked
_G.box_select = box_select
_G.box_insert = box_insert
