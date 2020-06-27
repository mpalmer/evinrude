Evinrude is an opinionated but flexible implementation of the [Raft distributed
consensus algorithm](https://raft.github.io/).  It is intended for use in any
situation where you need to be able to safely and securely achieve consensus
regarding the current state of a set of data in Ruby programs.


# Installation

It's a gem:

    gem install evinrude

There's also the wonders of [the Gemfile](http://bundler.io):

    gem 'evinrude'

If you're the sturdy type that likes to run from git:

    rake install

Or, if you've eschewed the convenience of Rubygems entirely, then you
presumably know what to do already.


# Usage

In order to do its thing, {Evinrude} needs at least two things: the contact
details of an existing member of the cluster, and the shared secret key for the
cluster.  Then, you create your {Evinrude} instance and set it running, like this:

```
c = Evinrude.new(join_hints: [{ address: "192.0.2.42", port: 31337 }], shared_keys: ["s3kr1t"])
c.run
```

The {Evinrude#run} method does not return in normal operation; you should call
it in a separate thread (or use a work supervisor such as
[Ultravisor](https://rubygems.org/gem/ultravisor)).

Once Evinrude is running, interaction with the data in the cluster is
straightforward.  To cause a change to be made to the data set, you call
{Evinrude#command} with a message which describes how the shared state of the
cluster should be changed (an application-specific language which it is up to you
to define), while to retrieve the currently-agreed state of the data set you
call {Evinrude#state}.

By default, the data set that is managed by consensus is a "register" -- a single
atomic string value, wherein the single value is the value of the most recent
{Evinrude#command} call that has been committed by the cluster.

Since a single "last-write-wins" string is often not a particularly useful thing
to keep coordinated, Evinrude allows you to provide a more useful state machine
implementation which matches the data model you're working with.


## The Machines of State

Because Evinrude is merely a Raft *engine*, it makes no assumptions about the
semantics of the data that is being managed.  For this reason, most non-trivial
uses of Evinrude will want to provide their own implementation of {Evinrude::StateMachine},
and provide it to the {Evinrude.new} call using the `state_machine` keyword
argument:

```
class MyStateMachine < Evinrude::StateMachine
  # interesting things go here
end

c = Evinrude.new(join_hints: [...], shared_keys: [ ... ], state_machine: MyStateMachine)

# ...
```

While the current state of the state machine is what we, as consumers of the
replicated data, care about, behind the scenes Raft deals entirely in a log of commands.
Each command (along with its arguments) may cause some deterministic change to the
internal state variables.  Exactly what commands are available, their arguments, and
what they do is up to your state machine implementation.

Thus, the core method in your state machine implementation is
{Evinrude::StateMachine#process_command}.  Similar to {Evinrude#command}, this
method accepts a string of arbitrary data, which it is the responsibility of
your state machine to decode and action.  In fact, the commands that your state
machine receives are the exact same ones that are provided to
{Evinrude#command}.  The only difference is that the only commands your state
machine will receive are those that the cluster as a whole has committed.

The other side, of course, is retrieving the current state.  That is handled by
{Evinrude::StateMachine#current_state}.  This method, which takes no arguments, can
return an arbitrary Ruby object that represents the current state of the
machine.

You don't need to worry about concurrency issues inside your state machine, by the way;
all calls to all methods on the state machine instance will be serialized via mutex.

It is *crucially* important that your state machine take no input from anywhere
other than calls to `#command`, and do nothing but modify internal state
variables.  If you start doing things like querying data in the outside world,
or interacting with anything outside the state machine in response to commands,
you will obliterate the guarantees of the replicated state machine model, and
all heck will, sooner or later, break loose.

One performance problem in a Raft state machine is the need to replay every log
message since the dawn of time in order to reproduce the current state when
(re)starting.  Since that can take a long time (and involve a lot of storage
and/or network traffic), Raft has the concept of *shapshots*.  These are string
representations of the entire current state of the machine.  Thus, your state
machine has to implement {Evinrude::StateMachine#snapshot}, which serializes
the current state into a string.  To load the state, a previously obtained
snapshot string will be passed to {Evinrude::StateMachine#initialize} in the
`snapshot` keyword argument.

... and that is the entire state machine interface.


## Persistent Storage

Whilst for toy systems you *can* get away with just storing everything in memory,
it's generally not considered good form for anything which you want to survive
long-term.  For that reason, you'll generally want to specify the `storage_dir`
keyword argument, specifying a directory which is writable by the user running
the process that is calling reating the object.

If there is existing state in that directory, it will be loaded before Evinrude
attempts to re-join the cluster.


## The Madness of Networks

By default, Evinrude will listen on the `ANY` address, on a randomly assigned
high port, and will advertise itself as being available on the first sensible-looking
(ie non-loopback/link-local) address on the listening port.

In a sane and sensible network, that would be sufficient (with the possible
exception of the "listen on the random port" bit -- that can get annoying for
discovery purposes).  However, so very, *very* few networks are sane and sensible,
and so there are knobs to tweak.

First off, if you need to control what address/port Evinrude listens on, you do
that via the `listen` keyword argument:

```
Evinrude.new(listen: { address: "192.0.2.42", port: 31337 }, ...)
```

Both `address` and `port` are optional; if left out, they'll be set to the appropriate
default.  So you can just control the port to listen on, for instance, by
setting `listen: { port: 31337 }` if you like.

The other half of the network configuration is the *advertisement*.  This is
needed because sometimes the address that Evinrude thinks it has is not the
address that other Evinrude instances must use to talk to it.  Anywhere NAT
rears its ugly head is a candidate for this -- Docker containers where
publishing is in use, for instance, will almost certainly fall foul of this.
For this reason, you can override the advertised address and/or port using
the `advertise` keyword argument:

```
Evinrude.new(advertise: { address: "192.0.2.42", port: 31337 })
```


## Bootstrapping and Joining a Cluster

A Raft cluster bootstraps itself by having the "first" node recognise that it is
all alone in the world, and configure itself as the single node in the cluster.
After that, all other new nodes need to told the location of at least one other
node in the cluster.  Existing cluster nodes that are restarted can *usually* use
the cluster configuration that is stored on disk, however a node which has been
offline while all other cluster nodes have changed addresses may still need to
use the join hints to find another node.

To signal to a node that it is the initial "bootstrap" node, you must explicitly
pass `join_hints: nil` to `Evinrude.new`:

```
# Bootstrap mode
c = Evinrude.new(join_hints: nil, ...)
```

Note that `nil` is *not* the default for `join_hints`; this is for safety, to avoid
any sort of configuration error causing havoc.

All other nodes in the cluster should be provided with the location of at least
one existing cluster member via `join_hints`.  The usual form of the `join_hints`
is an array of one or more of the following entries:

* A hash containing `:address` and `:port` keys; `:address` can be either an
  IPv4 or IPv6 literal address, or a hostname which the system is capable of
  resolving into one or more IPv4 or IPv6 addresses, while `:port` must be
  an integer representing a valid port number; *or*

* A string, which will be queried for `SRV` records.

An example, containing all of these:

```
c = Evinrude.new(join_hints: [
                       { address: "192.0.2.42", port: 1234 },
                       { address: "2001:db8::42", port: 4321 },
                       { address: "cluster.example.com", port: 31337 },
                       "cluster._evinrude._tcp.example.com"
                 ],
                ...)
```

As shown above, you can use all of the different forms together.  They'll
be resolved and expanded into a big list of addresses as required.


## Encryption Key Management

To provide at least a modicum of security, all cluster network communications
are encrypted using a symmetric cipher.  This requires a common key for
encryption and decryption, which you provide in the `shared_keys` keyword
argument:

```
c = Evinrude.new(shared_keys: ["s3krit"], ...)
```

The keys you use can be arbitrary strings of arbitrary length.  Preferably, you
want the string to be completely random and have at least 128 bits of entropy.
For example, you could use a string of 16 binary characters, encoded in
hex: `SecureRandom.hex(16)`.  The longer the better, but there's no point
having more than 256 bits of entropy, because your keys get hashed to 32 bytes
for use in the encryption algorithm.

As you can see from the above example, `shared_keys` is an *array* of strings,
not a single string.  This is to facilitate *key rotation*, if you're into that
kind of thing.

Since you don't want to interrupt cluster operation, you can't take down
all the nodes simultaneously to change the key.  Instead, you do the following,
assuming that you are using a secret key `"oldkey"`, and you want to
switch to using `"newkey"`:

1. Reconfigure each node, one by one, to set `shared_keys: ["oldkey", "newkey"]`
   (Note the order there is important!  `"oldkey"` first, then `"newkey"`)

2. When all nodes are running with the new configuration, then go around
   and reconfigure each node again, to set `shared_keys: ["newkey", "oldkey"]`
   (Again, *order is important*).

3. Finally, once all nodes are running with this second configuration, you
   can remove `"oldkey"` from the configuration, and restart everything
   with `shared_keys: ["newkey"]`, which retires the old key entirely.

This may seem like a lot of fiddling around, which is why you should always
use configuration management, which takes care of all the boring fiddling
around for you.

Why this works is because of how Evinrude uses the keys.  The first key
in the list is the key with which all messages are encrypted.  However any
received message can be decrypted with *any* key in the list.  Hence, the
three step process:

1. While you're doing step 1, everyone is encrypting with `"oldkey"`, so nobody
   will ever need to use `"newkey"` to decrypt anything, but that's OK.

2. While you're doing step 2, some nodes will be encrypting their messages with
   `"oldkey"` and some will be encrypting with `"newkey"`.  But since all the
   nodes can decrypt anything encrypted with *either* `"oldkey"` *or*
   `"newkey"` (because that's how they were configured in step 1), there's no
   problem.

3. By the time you start step 3, everyone is encrypting everything with
   `"newkey"`, so there's no problems with removing `"oldkey"` from the set of
   shared keys.


## Managing and Decommissioning Nodes

Because Raft works on a "consensus" basis, a majority of nodes must always
be available to accept updates and agree on the current state of the cluster.
This is true for both writes (changes to the cluster state), *as well as reads*.

Once a node has joined the cluster, it is considered to be a part of the
cluster forever, unless it is explicitly removed.  It is not safe for a node to
be removed automatically after some period of inactivity, because that node
could re-appear at any time and cause issues, including what is known as
"split-brain" (where there are two separate operational clusters, both of which
believe they know how things should be).

Evinrude makes some attempts to make the need to manually remove nodes rare.  In
many raft implementations, a node is identified by its IP address and port.  If
that changes, it counts as a new node.  When you're using a "dynamic network"
system (like most cloud providers), every time a server restarts, it gets a new
IP address, which is counted as a new node, and so quickly there's more old, dead
nodes than currently living ones, and the cluster completely seizes up.

In contrast, Evinrude nodes have a name as well as the usual address/port pair.  If a node
joins (or re-joins) the cluster with a name identical to that of a node already in
the cluster configuration, then the old node's address and port are replaced with
the address and port of the new one.

You can set one by hand, using the `node_name` keyword argument (although be
*really* sure to make them unique, or all heck will break loose), but if you
don't set one by hand, a new node will generate a UUID for its name.  If a node
loads its state from disk on startup, it will use whatever name was stored on disk.

Thus, if you have servers backed by persistent storage, you don't have to do
anything special: let Evinrude generate a random name on first startup, write out
its node name to disk, and then on every restart thereafter, the shared cluster configuration
will be updated to keep the cluster state clean.

Even if you don't have persistant storage, as long as you can pass the same
node name to the cluster node each time it starts, everything will still be
fine: the fresh node will give its new address and port with its existing name,
the cluster configuration will be updated, the new node will be sent the
existing cluster state, and off it goes.


### Removing a Node

All that being said, there *are* times when a cluster node has to be forcibly
removed from the cluster.  A few of the common cases are:

1. **Downsizing**: you were running a cluster of, say, nine nodes (because who
   *doesn't* want N+4 redundancy?), but a management decree says that for
   budget reasons, you can now only have five nodes (N+2 ought to be enough for
   anyone!).  In that case, you shut down four of the nodes, but the cluster
   will need to be told that they've been removed, otherwise as soon as one
   node crashes, the whole cluster will seize up.

2. **Operator error**: somehow (doesn't matter how, we all make mistakes
   sometimes) an extra node managed to join the cluster.  You nuked it before
   it did any real damage, but the cluster config still thinks that node should
   be part of the quorum.  It needs to be removed before All Heck Breaks Loose.

3. **Totally Dynamic Environment**: if your cluster members have *no* state
   persistence, not even being able to remember their name, nodes will need to
   gracefully deregister themselves from the cluster when they shutdown.
   **Note**: in this case, nodes that crash and burn without having a chance to
   gracefully say "I'm outta here" will clog up the cluster, and sooner or
   later you'll have more ex-nodes than live nodes, leading to eventual
   Confusion and Delay.  Make sure you've got some sort of "garbage collection"
   background operation running, that can identify permanently-dead nodes and
   remove them from the cluster before they cause downtime.

In any event, the way to remove a node is straightforward: from any node currently
in the cluster, call {Evinrude#remove_node}, passing the node's info:

```
c = Evinrude.new(...)
c.remove_node(Evinrude::NodeInfo.new(address: "2001:db8::42", port: 31337, name: "fred"))
```

This will notify the cluster leader of the node's departure, and the cluster
config will be updated.

Removing a node requires the cluster to still have consensus (half the
cluster nodes running), for the new configuration to take effect.  This is so the
removal can be safe, by doing Raft Trickery to ensure that the removed node
can't cause split-brain issues on its way out the door.


### Emergency Removal of a Node

If your cluster has completely seized up, due to more than half of
the nodes in the cluster configuration being offline, things are somewhat trickier.
In this situation, you need to do the following:

1. Make 110% sure that the node (or nodes) you're removing aren't coming back any
   time soon.  If the nodes you're removing spontaneously reappear, you can end
   up with split-brain.

2. Locate the current cluster leader node.  The {Evinrude#leader?} method is your
   friend here.  If no node is the leader, then find a node which is a candidate
   instead (with {Evinrude#candidate?} and use that.

3. Request the removal of a node with {Evinrude#remove_node}, but this time pass the
   keyword argument `unsafe: true`.  This bypasses the consensus checks.

The reason why you need to do this on the leader is because the new config that
doesn't have the removed node needs to propagate from the leader to the rest of
the cluster.  When the cluster doesn't have a leader, removing the node from a
candidate allows that candidate to gather enough votes to consider itself a
leader, at which point it can propagate its configuration to the other nodes.

In almost all cases, you'll need to remove several nodes in order to get the
cluster working again.  Just keep removing nodes until everything comes back.

Bear in mind that if your cluster split-brains as a result of passing `unsafe:
true`, you get to keep both pieces -- that's why the keyword's called `unsafe`!


# Contributing

Please see [CONTRIBUTING.md](CONTRIBUTING.md).


# Licence

Unless otherwise stated, everything in this repo is covered by the following
copyright notice:

    Copyright (C) 2020  Matt Palmer <matt@hezmatt.org>

    This program is free software: you can redistribute it and/or modify it
    under the terms of the GNU General Public License version 3, as
    published by the Free Software Foundation.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
