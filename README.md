# DAS emulator

Emulate DAS DHT behavior, with a few simplifying assumptions:

- the block is populated in the DHT by the builder (node 0)
- all nodes start sampling at the same time
- 1-way latency is 50ms (configurable)
- no losses in transmission (configurable)
- scaled down numbers (nodes, blocksize, etc., all configrable)
