## Overview

The basic information on the merger API is provided in the commit message where
the merger was introduced. Please refer it first. This document and other
repository content expands the API description with usage examples.

TBD: paste a link.

## API and basic usage

The basic case of using merger is when there are M storages and data are
partitioned (sharded) across them. A client want to fetch a tuple stream from
each storage and merge them into one tuple stream:

```lua
local msgpack = require('msgpack')
local net_box = require('net.box')
local buffer = require('buffer')
local key_def = require('key_def')
local merger = require('merger')

-- Prepare M connections.
local net_box_opts = {reconnect_after = 0.1}
local connects = {
    net_box.connect('localhost:3301', net_box_opts),
    net_box.connect('localhost:3302', net_box_opts),
    ...
    net_box.connect('localhost:<...>', net_box_opts),
}

-- Set key parts from an index.
-- See the 'How to form key parts' section below.
local key_parts = {}
local space = connects[1].space.<...>
local index = space.index.<...>
local key_def_inst = key_def.new(index.parts)
if not index.unique then
    key_def_inst = key_def_inst:merge(key_def.new(space.index[0].parts))
end

-- Create a merger context.
-- NB: It worth to cache it.
local ctx = merger.context.new(key_def_inst)

-- Prepare M sources.
local sources = {}
for _, conn in ipairs(connects) do
    local buf = buffer.ibuf()
    conn.space.<...>.index.<...>:select(<...>, {buffer = buf,
        skip_header = true})
    table.insert(sources, merger.new_source_frombuffer(buf))
end

-- Merge.
local merger_inst = merger.new(ctx, sources)
local res = merger_inst:select()
```

## How to form key parts

The merger expects that each input tuple stream is sorted in the order that
acquired for a result (via key parts and the `reverse` flag). It performs a
kind of the merge sort: chooses a source with a minimal / maximal tuple on each
step, consumes a tuple from this source and repeats.

A :select() or a :pairs() from a space gives tuples in the order that
corresponds to an index. Key parts from this index should be used to perform
merge of such selects.

A secondary non-unique index sort tuples that are equal by parts of the index
according to a primary index order (we can imagine that as if a non-unique
index would have hidden key parts copied from a primary index).

So when one perform a merge of select results received via a non-unique index a
primary index key parts should be added after a non-unique index key parts. The
example above shows this approach with using `key_def_inst:merge()` method.

## Preparing buffers

### In short

* Use `skip_header = true` option for a `:select()` net.box request.
* In addition use `msgpack.decode_array()` function to postprocess a
  net.box :call() result.

See the example in the 'API and basic usage' section for the former
bullet and the example in the 'Multiplexing requests' section for the
latter one.

### In details

We'll use the symbol T below to represent an msgpack array that
corresponds to a tuple.

A select response has the following structure: `{[48] = {T, T, ...}}`,
while a call response is `{[48] = {{T, T, ...}}}` (because it should
support multiple return values). A user should skip extra headers and
pass a buffer with the read position on `{T, T, ...}` to a merger.

Note: `{[48] = ...}` wrapper is referred below as iproto_data header.

Typical headers are the following:

Cases            | Buffer structure
---------------- | ----------------
raw data         | {T, T, ...}
net.box select   | {[48] = {T, T, ...}}
net.box call     | {[48] = {{T, T, ...}}}

See also the following docbot requests:

* Non-recursive msgpack decoding functions.
* net.box: skip_header option.

XXX: add links.

How to check buffer data structure myself:

```lua
local net_box = require('net.box')
local buffer = require('buffer')
local ffi = require('ffi')
local msgpack = require('msgpack')
local yaml = require('yaml')

box.cfg{listen = 3301}
box.once('load_data', function()
    box.schema.user.grant('guest', 'read,write,execute', 'universe')
    box.schema.space.create('s')
    box.space.s:create_index('pk')
    box.space.s:insert({1})
    box.space.s:insert({2})
    box.space.s:insert({3})
    box.space.s:insert({4})
end)

local function foo()
    return box.space.s:select()
end
_G.foo = foo

local conn = net_box.connect('localhost:3301')

local buf = buffer.ibuf()
conn.space.s:select(nil, {buffer = buf})
local buf_str = ffi.string(buf.rpos, buf.wpos - buf.rpos)
local buf_lua = msgpack.decode(buf_str)
print('select:\n' .. yaml.encode(buf_lua))

local buf = buffer.ibuf()
conn:call('foo', nil, {buffer = buf})
local buf_str = ffi.string(buf.rpos, buf.wpos - buf.rpos)
local buf_lua = msgpack.decode(buf_str)
print('call:\n' .. yaml.encode(buf_lua))

os.exit()
```

## Chunked data transfer

The merger can ask for further data from a drained source when one of the
following functions are used to create a source:

* merger.new_buffer_source(gen, param, state)
* merger.new_table_source(gen, param, state)
* merger.new_tuple_source(gen, param, state)

A `gen` function should return the following values correspondingly:

* <state>, <buffer> or <nil>
* <state>, <table> or <nil>
* <state>, <tuple> or <nil>

Note: The merger understands both tuples and Lua tables ({...} and
box.tuple.new({...})) as input tuples in a table and a tuple source, but we
refer them just as tuples for simplicity.

Each of returned buffer or table represents a chunk of data. In case of tuple
source a chunk always consists of one tuple. When there are no more chunks a
`gen` function should return `nil`.

The following example fetches a data from two storages in chunks. A first
request uses ALL iterator and BLOCK_SIZE limit, the following ones use the same
limit and GT iterator (with a key extracted from a last fetched tuple).

Note: such way to implement a cursor / a pagination will work smoothly only
with unique indexes. See also #3898.

More complex scenarious are possible: using futures (`is_async = true`
parameters of net.box methods) to fetch a next chunk while merge a current one
or, say, call a function with several return values (some of them need to be
skipped manually in a `gen` function to let merger read tuples).

Note: When using `is_async = true` net.box option one can lean on the fact that
net.box writes an answer w/o yield: a partial result cannot be observed.

```lua
-- Storage script
-- --------------

-- See chunked_example/storage.lua.

-- Client script
-- -------------

-- See chunked_example/frontend.lua.
```

Let show which optimization can be applied here:

* Using buffer sources to avoid unpacking a tuple data recursively into Lua
  objects (that can lead to much extra LuaJIT GC work).
* Fire a next request asynchronously once we receive the previous one, but
  before we'll process it. So we'll fetch data in background while performing a
  merge.

These optimizations let us introduce a stored procedure on storages that will
return a cursor and data. On a client we'll wait for Nth request, decode only
cursor from it, asynchronously fire (N+1)th request and return Nth data to a
merger.

The example below provides simple cursor implementation (only for unique
indexes) and use vshard API on a client.

```lua
-- Storage script
-- --------------

-- See chunked_example_fast/storage.lua.

-- Client script
-- -------------

-- See chunked_example_fast/frontend.lua.
```

## Multiplexing requests

Consider the case when a network latency between storage machines and frontend
machine(s) is much larger then a time to process a request on a frontend. This
situation is typical when a workload consists of many small requests.

So it can be worth to 'multiplex' different requests to storage machines within
one network request. We'll consider approach when a storage function returns
many box.space.<...>:select(<...>) results instead of one.

One need to skip iproto_data header, two array headers and then run a merger N
times on the same buffers (with the same or different contexts). No extra data
copies, no tuples decoding into a Lua memory.

```lua
-- Storage script
-- --------------

-- See multiplexed_example/storage.lua.

-- Client script
-- -------------

-- See multiplexed_example/frontend.lua.
```

## Cascading mergers

The idea is simple: a merger instance itself is a merger source.

The example below is synthetic to be simple. Real cases when cascading can be
profitable likely involve additional layers of Tarantool instances between a
storage and a client or separate threads to merge blocks of each level.

To be honest no one use this ability for now. It exists, because the same
behaviour for a source and a merger looks as the good property of the API.

```lua
<...requires...>

local sources = <...100 sources...>
local ctx = merger.context.new(key_def.new(<...>))

-- Create 10 mergers with 10 sources in each.
local middleware_mergers = {}
for i = 1, 10 do
    local current_sources = {}
    for j = 1, 10 do
        current_sources[j] = sources[(i - 1) * 10 + j]
    end
    middleware_mergers[i] = merger.new(ctx, current_sources)
end

-- Note: Using different contexts will lead to extra copying of
-- tuples.
local res = merger.new(ctx, middleware_mergers):select()
```
