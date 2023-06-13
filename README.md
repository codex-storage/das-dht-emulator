# DAS emulator

Emulate DAS DHT behavior, with a few simplifying assumptions:

- the block is populated in the DHT by the builder (node 0)
- all nodes start sampling at the same time
- 1-way latency is 50ms (configurable)
- no losses in transmission (configurable)
- scaled down numbers (nodes, blocksize, etc., all configrable)

## Quick start

```
git clone https://github.com/codex-storage/das-dht-emulator
cd das-dht-emulator
make NIMFLAGS="-d:asyncTimer=virtual" -j4
build/das
```

## Features

### Emulating many nodes
The emulator support the creation of a large number of DHT nodes in a single process. Due to the memory-efficiency of Nim, this easily means thousands of nodes. Multi-thread and multi-process is not yet supported. 

### In-memory networking
The DHT code uses UDP for communication between Nodes. This could create a few issues:
- some UDP ports might not be available, which needs handling
- frequent switches between user space and kernel space, with copying of data

To solve this, the emulator can replace the UDP stack with its own in-memory message passing. This is done by replacing chronos/DatagramTransport.

### Network emulation
The emulator can add delays, losses, and queuing behavior. This is currently configured in code.

### Timer manipulation
By default the emulator runs all nodes in real-time on the host processor, in one thread. This can easily create issues, as the node CPU core gets overloaded, and
delay is accumulated in processing. To overcome this there are two features

- TimeWarp: allows to slow down time by a factor, allowing the CPU more time to handle calculations. TimeWarp=10 means that every timer will be multiplied by 10, making a 50ms transmission delay to take 500ms, and a 3s timeout to wait 30s.
Currently set in code

- asyncTimer=virtual: this introduces dynamic timing, detached from the real clock. The emulation (or maybe simulation at this point) will step through the event queue as fast as it can. All CPU operations take 0 virtual time, independent of real CPU time. All gaps between events take 0 real time. 
```
make NIMFLAGS="-d:asyncTimer=virtual"
```

### Dummy encryption
Since encryption is not needed in the emulation it can be turned off.

- Symmetric cipher on UDP packets: this is replaced by default with a NOP cipher, saving CPU time and also simplifying debugging
- Asymmetric cipher for signatures: this is not yet replaced, which results in an increased node setup time
