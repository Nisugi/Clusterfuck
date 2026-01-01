# Cluster.lic Documentation

The Cluster system enables distributed communication between multiple Lich5 scripts across different characters using Redis pub/sub for coordination and information sharing.

## Table of Contents

- [Overview](#overview)
- [Setup Requirements](#setup-requirements)
- [Communication Patterns](#communication-patterns)
  - [Broadcasts (One-to-Many)](#broadcasts-one-to-many)
  - [Casts (One-to-One)](#casts-one-to-one)
  - [Requests (Request-Response)](#requests-request-response)
  - [Group Channels (Secure Groups)](#group-channels-secure-groups)
- [Contracts System](#contracts-system)
- [Registry (Key-Value Storage)](#registry-key-value-storage)
- [Best Practices](#best-practices)
- [Debugging](#debugging)

---

## Overview

Cluster provides a distributed messaging framework for coordinating multiple GemStone IV characters running Lich5 scripts. Key features include:

- **Broadcasts**: Send messages to all connected characters
- **Casts**: Send messages to a specific character
- **Requests**: Send messages and wait for a response
- **Group Channels**: Secure, ephemeral channels for private group communication
- **Contracts**: Auction-style bidding system for task assignment
- **Registry**: Shared key-value storage across characters

---

## Setup Requirements

### Prerequisites

1. **Redis Server** - Self-hosted or cloud-based (e.g., Redis Cloud, AWS ElastiCache)
2. **Ruby Gems** - `redis` and `connection_pool`

### Installation

```bash
gem install redis connection_pool
```

### Starting Cluster

```bash
# Default connection
;cluster

# Custom Redis URL
;cluster --url=redis://your-server:6379

# Enable debug mode
;cluster --debug
```

### Configuration

Create a `cluster_callbacks.rb` file in your scripts directory to define your message handlers.

---

## Communication Patterns

### Broadcasts (One-to-Many)

Send messages to all connected characters except yourself.

#### Sending Broadcasts

```ruby
# Simple broadcast
Cluster.broadcast(:begin_hunt)

# Broadcast with data
Cluster.broadcast(:command, val: '?')
Cluster.broadcast(:party_move, room_id: Room.current.id, direction: 'north')
```

#### Receiving Broadcasts

```ruby
Cluster.on_broadcast(:begin_hunt) do |_, req|
  echo "Starting hunt routine from #{req.from}"
  Script.start('hunter')
end

Cluster.on_broadcast(:command) do |_, req|
  do_client req.val
end

Cluster.on_broadcast(:party_move) do |_, req|
  echo "Moving to room #{req.room_id}"
  # Handle movement logic
end
```

---

### Casts (One-to-One)

Send direct messages to specific characters.

#### Sending Casts

```ruby
# Direct message to a character
Cluster.cast('John', channel: :command, val: '?')

# Request skin service from a specific character
Cluster.cast(Settings[:force_skinner], channel: :skin_room, roomId: Room.current.id)

# Send healing request
Cluster.cast('Healer', channel: :heal_request, target: Char.name, health: percenthealth)
```

#### Receiving Casts

```ruby
Cluster.on_cast(:command) do |_, req|
  do_client req.val
end

Cluster.on_cast(:skin_room) do |_, req|
  if Room.current.id == req.roomId
    Script.start('skinning')
  end
end

Cluster.on_cast(:heal_request) do |_, req|
  echo "Heal request from #{req.from} - health: #{req.health}%"
  # Handle healing logic
end
```

---

### Requests (Request-Response)

Synchronous request-response pattern with timeout support.

#### Sending Requests

```ruby
# Basic request (default 5 second timeout)
response = Cluster.request('John', channel: :ready_to_move)

# Request with custom timeout
response = Cluster.request('John', channel: :ready_to_move, timeout: 10)

# Async request (non-blocking)
req_thread = Cluster.async_request('John', channel: :ready_to_move)
# ... do other work ...
response = req_thread.value

# Map request to multiple characters
characters = ['John', 'Paul', 'Ringo']
responses = Cluster.map(characters, channel: :ready_to_move)
```

#### Handling Requests

```ruby
Cluster.on_request(:ready_to_move) do |_, req|
  # Return a hash with response data
  {
    ready: checkrt.eql?(0) && standing?,
    health: percenthealth,
    mana: percentmana
  }
end

Cluster.on_request(:status_check) do |_, req|
  {
    character: Char.name,
    room: Room.current.id,
    standing: standing?,
    rt: checkrt
  }
end
```

#### Handling Response Errors

```ruby
response = Cluster.request('John', channel: :status)

if response.is_a?(Exception)
  echo "Request failed: #{response.message}"
elsif response.is_a?(TimeoutError)
  echo "Request timed out"
else
  echo "Got response: #{response.inspect}"
end
```

---

### Group Channels (Secure Groups)

Private channels that only group members can see. Unlike broadcasts which go to all connected characters, group messages are only delivered to characters subscribed to that specific group channel at the Redis level.

#### Channel Architecture

```
Public:    gs.pub.*           -> All characters receive
Personal:  gs.<charname>.*    -> Only that character receives
Group:     gs.grp.<groupid>.* -> Only group members receive
```

#### Creating and Joining Groups

```ruby
# Leader creates a group with a secure random ID
group_id = SecureRandom.hex(4)  # e.g., "a3f2b1c9"
Cluster.join_group(group_id)

# Share the group ID securely (whisper in-game)
fput "whisper #{member} join my group: #{group_id}"

# Member joins the same group
Cluster.join_group("a3f2b1c9")
```

#### Sending Group Messages

```ruby
# Broadcast to group members only
Cluster.group_broadcast(:attack, target_id: 12345)
Cluster.group_broadcast(:move, room_id: Room.current.id)
Cluster.group_broadcast(:rest)

# Check group status
echo "In group: #{Cluster.in_group?}"
echo "Group ID: #{Cluster.current_group}"
```

#### Receiving Group Messages

```ruby
# Register handlers for group channels
Cluster.on_group(:attack) do |_, req|
  echo "Attack signal from #{req.from}"
  # Engage combat
end

Cluster.on_group(:move) do |_, req|
  Script.start('go2', req.room_id.to_s)
end

Cluster.on_group(:rest) do |_, req|
  echo "Rest signal from #{req.from}"
  # Begin rest routine
end
```

#### Leaving Groups

```ruby
# Explicit leave
Cluster.leave_group

# Automatic cleanup on script exit (handled by destroy())
```

#### Best Practices for Groups

**Use sufficiently random group IDs:**
```ruby
# Good - 8 hex chars
SecureRandom.hex(4)  # "a3f2b1c9"

# Better for sensitive operations
SecureRandom.hex(8)  # "a3f2b1c94e7d8a2f"
```

**Register handlers before or immediately after joining:**
```ruby
Cluster.join_group(group_id)
Cluster.on_group(:attack) { |_, req| handle_attack(req) }
Cluster.on_group(:move) { |_, req| handle_move(req) }
```

**Validate sender in handlers:**
```ruby
TRUSTED_MEMBERS = ['Tank', 'Healer', 'DPS']

Cluster.on_group(:attack) do |_, req|
  next unless TRUSTED_MEMBERS.include?(req.from)
  handle_attack(req)
end
```

**Clean up on exit:**
```ruby
before_dying do
  Cluster.leave_group if Cluster.in_group?
end
```

#### Group Channel Methods

| Method | Description |
|--------|-------------|
| `Cluster.join_group(id)` | Subscribe to group channel (replaces any existing group) |
| `Cluster.leave_group` | Unsubscribe from current group |
| `Cluster.current_group` | Returns current group ID or nil |
| `Cluster.in_group?` | Returns true if in a group |
| `Cluster.group_broadcast(ch, **data)` | Send message to group members only |
| `Cluster.on_group(ch, &block)` | Register handler for group messages |

---

## Contracts System

An auction mechanism where characters bid to perform tasks. The highest bidder wins the contract.

### Defining Contract Handlers

```ruby
Contracts.on_contract(:poisoned, {
  # Called when a contract is opened - return bid value (0.0 to 1.0)
  # Return -1 to decline
  contract_open: -> req {
    return -1 unless Spell[114].known?      # Must know Unpoison
    return -1 unless Spell[114].affordable?  # Must have mana
    percentmana / 100.0                      # Bid based on mana %
  },

  # Called when this character wins the contract
  contract_win: -> req {
    echo "Casting Unpoison on #{req.from}"
    Spell[114].cast(req.from)
  }
})

Contracts.on_contract(:heal_me, {
  contract_open: -> req {
    return -1 unless Spell[1120].known?
    return -1 if percentmana < 20
    percentmana / 100.0
  },
  contract_win: -> req {
    Spell[1120].cast(req.from)
  }
})
```

### Collecting Bids

```ruby
# Basic contract collection
Contracts.collect_bids(:poisoned)

# Limit to specific bidders
Contracts.collect_bids(:poisoned, valid_bidders: GameObj.pcs.map(&:noun))

# Set minimum bid threshold
Contracts.collect_bids(:heal_me,
  valid_bidders: ['John', 'Paul', 'Ringo'],
  min_bid: 0.5
)
```

### Bid Values

- `1.0` - Highest priority (will definitely win if possible)
- `0.5` - Medium priority
- `0.0` - Lowest priority (will only win if no other bids)
- `-1` - Decline the contract (cannot perform the task)

---

## Registry (Key-Value Storage)

Shared key-value storage accessible across all connected characters.

### Basic Usage

```ruby
# Get default registry
reg = Cluster.registry

# Store values
reg.put('last_hunt_room', Room.current.id)
reg.put('party_leader', Char.name)
reg.put('hunt_config', { min_health: 50, max_rt: 3 }.to_json)

# Retrieve values
room_id = reg.get('last_hunt_room')
leader = reg.get('party_leader')

# Check existence
if reg.exists?('party_leader')
  echo "Party leader: #{reg.get('party_leader')}"
end

# Delete values
reg.delete('old_data')
```

### Namespaced Registries

```ruby
# Create namespaced registry
party_reg = Cluster.registry('party')
party_reg.put('meeting_room', 12345)
party_reg.put('members', ['John', 'Paul', 'Ringo'].to_json)

hunt_reg = Cluster.registry('hunt')
hunt_reg.put('current_area', 'Darkstone Castle')
hunt_reg.put('kills', 0)
```

---

## Best Practices

### 1. Connection Management

Always check connection status before sending messages:

```ruby
if Cluster.connected
  Cluster.broadcast(:status_update, data: current_status)
else
  echo "Cluster not connected!"
end
```

### 2. Error Handling

Validate responses for exceptions and timeouts:

```ruby
response = Cluster.request('John', channel: :status, timeout: 5)

case response
when TimeoutError
  echo "Request timed out - John may be offline"
when Exception
  echo "Request failed: #{response.message}"
else
  process_response(response)
end
```

### 3. Defensive Programming

Validate prerequisites before acting on messages:

```ruby
Cluster.on_cast(:heal_target) do |_, req|
  # Validate we're in the same room
  next unless Room.current.id == req.room_id

  # Validate target exists
  target = GameObj.pcs.find { |pc| pc.noun == req.target }
  next unless target

  # Validate we can cast
  next unless Spell[1120].affordable?

  Spell[1120].cast(target)
end
```

### 4. Use `next` vs `return`

- Use `next` in callbacks (`on_broadcast`, `on_cast`, `on_request`)
- Use `return` in contract lambdas (`contract_open`, `contract_win`)

### 5. Appropriate Timeouts

- **Quick checks**: 2-3 seconds (status, ready checks)
- **Standard operations**: 5 seconds (default)
- **Complex tasks**: 10-30 seconds (movement, combat actions)

### 6. Data Validation

Always validate required fields and types:

```ruby
Cluster.on_request(:party_invite) do |_, req|
  # Validate required fields
  next { error: 'missing room_id' } unless req.respond_to?(:room_id)
  next { error: 'invalid room_id' } unless req.room_id.is_a?(Integer)

  { accepted: true, character: Char.name }
end
```

---

## Debugging

### Enable Debug Mode

```bash
;cluster --debug
```

### Check Connection Status

```ruby
;e echo Cluster.connected.inspect
;e echo Cluster.alive?('John')
```

### Test Communication

```ruby
# Test broadcast
;e Cluster.broadcast(:test, message: 'hello')

# Test cast
;e Cluster.cast('John', channel: :test, data: 123)

# Test request
;e p Cluster.request('John', channel: :test)
```

### Common Issues

| Issue | Solution |
|-------|----------|
| Messages not received | Check Redis connection, verify character is running cluster |
| Timeouts | Increase timeout value, check target character status |
| Contract not winning | Verify bid value > 0, check contract_open returns valid bid |
| Registry data missing | Check namespace, verify Redis persistence settings |

---

## Quick Reference

| Method | Purpose | Example |
|--------|---------|---------|
| `Cluster.broadcast` | Send to all | `Cluster.broadcast(:event, data: val)` |
| `Cluster.cast` | Send to one | `Cluster.cast('Name', channel: :ch, data: val)` |
| `Cluster.request` | Request-response | `Cluster.request('Name', channel: :ch)` |
| `Cluster.async_request` | Non-blocking request | `thread = Cluster.async_request(...)` |
| `Cluster.map` | Multi-character request | `Cluster.map(['A','B'], channel: :ch)` |
| `Cluster.join_group` | Join secure group | `Cluster.join_group('a3f2b1c9')` |
| `Cluster.leave_group` | Leave current group | `Cluster.leave_group` |
| `Cluster.group_broadcast` | Send to group only | `Cluster.group_broadcast(:event, data: val)` |
| `Cluster.on_group` | Handle group messages | `Cluster.on_group(:ch) { \|_, req\| ... }` |
| `Cluster.in_group?` | Check if in group | `if Cluster.in_group?` |
| `Cluster.current_group` | Get group ID | `echo Cluster.current_group` |
| `Cluster.connected` | Check connection | `if Cluster.connected` |
| `Cluster.alive?` | Check character online | `Cluster.alive?('Name')` |
| `Cluster.registry` | Get key-value store | `reg = Cluster.registry('ns')` |
| `Contracts.on_contract` | Define contract handler | See Contracts section |
| `Contracts.collect_bids` | Start auction | `Contracts.collect_bids(:task)` |
