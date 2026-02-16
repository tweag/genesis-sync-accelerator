# Using a Genesis Sync Accelerator

## Introduction and motivation
If you're running a node which has never connected to the Cardano network, or has not connected in quite some time, it's time-consuming to get the node up-to-date with the current best chain. 
To ease this burden, you can point your node to an instance of a Genesis Sync Accelerator, which you expect to serve you the block data more quickly (and more reliably) than a random peer on the network.

In practice, you will run this data service locally, with the data coming from a trusted source from which reads are quick and cheap. 
The data service running locally provides the ChainSync and BlockFetch mini-protocols in responder mode, so it will handle requests coming from your syncing node.

## Configuration example

### Node configuration file
At the time of writing, Genesis is _not_ used by default. 
To enable it, set `"ConsensusMode": "GenesisMode"`, or use `--ConsensusMode GenesisMode` when starting your node.

### Topology file
Once your local Accelerator instance is running, using it to power the sync of your node is as simple as telling the node where the Accelerator is serving data. Specifically, you can create an entry in the `localRoots` value of the [topology file](https://developers.cardano.org/docs/get-started/infrastructure/node/topology/). Here's an example, for using an Accelerator serving data at 127.0.0.1 on port 3001:
```json
{
  "localRoots": [
    {
      "accessPoints": [
        {
          "address": "127.0.0.1",
          "port": 3001
        }
      ],
      "advertise": false,
      "trustable": true,
      "hotValency": 1
    }
  ],
  "bootstrapPeers": null,
  "peerSnapshotFile": "peer-snapshot.json",
  "publicRoots": []
}
```
This indicates that the node should maintain one active ("hot") connection with the Accelerator; in practice, if there were additional access points, and you wanted more than just one active connection, you could adjust the `hotValency` value.
More important, this configuration says that the node should _not_ advertise the Accelerator as a peer to other nodes: in general, you'd like to not bog down your fast data service with additional request traffic.
Furthermore, the above declaration adds a _necessary_ (for syncing in Genesis mode) pointer to a "peer snapshot file", which is a record of the "biggest" peers at a moment in time, according to their share of stake (in ADA). 
These are peers with which your syncing node will communicate and which will, in general, be offering block headers during syncing which either refute or corroborate what's being advertised by your Accelerator instance.
For a bit more, about the syncing via Genesis, refer to the [Genesis section](https://developers.cardano.org/docs/get-started/infrastructure/node/topology/#ouroboros-genesis) of the documentation about the topology file.

## Why it works
When a node is syncing by using Genesis, at any given time only one active peer will be providing actual block data, while the others will be corroborating (or refuting) what's proposed by the block-yielding peer, proposing their own version of the blockchain by advertising block headers.
With an Accelerator among the `localRoots`, it's in the pool of peers with which your syncing node will strive to maintain some number (`hotValency`) of active connections.
Through a __round-robin process__ by which the syncing node cycles through active peers, the Accelerator will eventually become the one peer serving actual block data. 
Since it's running locally, it will likely be able to serve data more quickly than other peers, and will "win out" as the peer most capable of saturating the syncing node's block processing capacity.

## Worst-case scenario
The _absolute_ worst-case scenario, of course, is _"eclipse"_, when adversarial nodes control more than 50% of stake. 
In this case, Genesis cannot protect against a node being led astray onto an untrue chain, but neither can Praos. 

Critically, though, even if you choose to use a Genesis Sync Accelerator to power the sync for your node, Genesis _does_ protect you from being led onto the wrong chain so long as _adversarial stake is under 50%_. 
This is in spite of the fact that by using an Accelerator, you're biasing the sync toward using a single source of block data. 
Even if the data source upstream of the Accelerator were adversarial (or just wrong for whatever reason), Genesis guarantees you protection from falling onto an untrue chain.

Specifically, if the data served by the Accelerator is not corroborated by the syncing node's other active peers, the sync will stall. 
The connection to the Accelerator will be dropped upon learning that it's serving bad data, but the configuration which allows it to be used at all will cause the node to reconnect to the Accelerator very shortly after the disconnect, and it will once again dominate others in terms of speed at which it can serve data to the syncing node. 
The Accelerator will again be quickly discredited by the other active (honest) peers, and this cycle will continue. 
Ultimately, this could result in __stalled or very slow sync__. 
Again, though, Genesis guarantees that _an untrue chain will not be selected_ (assuming adversarial stake share doesn't clear 50%).

### Remediation
If you notice that your syncing node is making very slow (or no) progress--especially if it's apparent that it's communicating with the Accelerator for block data--try removing the Accelerator from the topology file.

## Potential pitfalls
* Even slow peers could saturate the syncing node (but then this is not really a problem, as the node itself--and not the data service--is the bottleneck).
* Even the Accelerator may not saturate the syncing node's block processing capacity. Then the Accelerator would still be cycled away from, just as any other peer in the round-robin.

