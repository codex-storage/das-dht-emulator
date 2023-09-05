import
  std/[random, math],
  chronicles,
  chronos,
  libp2pdht/discv5/crypto as dhtcrypto,
  libp2pdht/discv5/protocol as discv5_protocol,
  tests/dht/test_helper

logScope:
  topics = "DAS emulator"
  simTime = Moment.now() - simStartTime

let 
  simStartTime = Moment.now()

proc bootstrapNodes(
    nodecount: int,
    bootnodes: seq[SignedPeerRecord],
    rng = newRng(),
    delay: int = 0
  ) : Future[seq[(discv5_protocol.Protocol, PrivateKey)]] {.async.} =

  debug "---- STARTING BOOSTRAPS ---"
  for i in 0..<nodecount:
    try:
      let privKey = PrivateKey.example(rng)
      let node = initDiscoveryNode(rng, privKey, localAddress(20302 + i), bootnodes)
      await node.start()
      result.add((node, privKey))
      if delay > 0:
        await sleepAsync(chronos.milliseconds(delay))
    except TransportOsError as e:
      echo "skipping node ",i ,":", e.msg

  #await allFutures(result.mapIt(it.bootstrap())) # this waits for bootstrap based on bootENode, which includes bonding with all its ping pongs

proc bootstrapNetwork(
    nodecount: int,
    rng = newRng(),
    delay: int = 0
  ) : Future[seq[(discv5_protocol.Protocol, PrivateKey)]] {.async.} =

  let
    bootNodeKey = PrivateKey.fromHex(
      "a2b50376a79b1a8c8a3296485572bdfbf54708bb46d3c25d73d2723aaaf6a617")
      .expect("Valid private key hex")
    bootNodeAddr = localAddress(20301)
    bootNode = initDiscoveryNode(rng, bootNodeKey, bootNodeAddr, @[]) # just a shortcut for new and open

  #waitFor bootNode.bootstrap()  # immediate, since no bootnodes are defined above

  var res = await bootstrapNodes(nodecount - 1,
                           @[bootnode.localNode.record],
                           rng,
                           delay)
  res.insert((bootNode, bootNodeKey), 0)
  return res

proc toNodeId(data: openArray[byte]): NodeId =
  readUintBE[256](keccak256.digest(data).data)

proc segmentData(s: int, segmentsize: int) : seq[byte] =
  result = newSeq[byte](segmentsize)
  var
    r = s
    i = 0
  while r > 0:
    assert(i<segmentsize)
    result[i] = byte(r mod 256)
    r = r div 256
    i+=1

proc sample(s: Slice[int], len: int): seq[int] =
    # random sample without replacement
    # TODO: not the best for small len
  assert s.a <= s.b
  var all = s.b - s.a + 1
  var count = len
  if len >= all div 10: # add better algo selector
    var generated = newSeq[bool](all) # Initialized to false.
    while count != 0:
      let n = rand(s)
      if not generated[n - s.a]:
        generated[n - s.a] = true
        result.add n
        dec count
  else:
    while count != 0:
      let n = rand(s)
      if not (n in result):
        result.add n
        dec count


when isMainModule:
  proc main() {.async.} =
    let
      nodecount = 100
      delay_pernode = 10 # in millisec
      blocksize = 256
      segmentsize = 2
      samplesize = 3
      sampling_timeout = 5.seconds
      samplethreshold = samplesize
      delay_init = 60.minutes
      upload_timeout = 4.seconds
      sampling_delay = 4.seconds
    assert(log2(blocksize.float).ceil.int <= segmentsize * 8 )
    assert(samplesize <= blocksize)

    var
      segmentIDs = newSeq[NodeId](blocksize)

    # start network
    let
      rng = newRng()
      nodes = await bootstrapNetwork(nodecount=nodecount, delay=delay_pernode)

    # wait for network to settle
    info "waiting for DHT to settle"
    await sleepAsync(delay_init)

    let uploadStartTime = Moment.now()
    # generate block and push data
    info "starting upload to DHT"
    var uploads = newSeq[Future[seq[Node]]]()
    for s in 0 ..< blocksize:
      let
        segment = segmentData(s, segmentsize)
        key = toNodeId(segment)

      segmentIDs[s] = key

    # start measuring time
      let upload = nodes[0][0].addValue(key, segment)
      upload.addCallback proc(udata: pointer) =
        info "uploaded to DHT", by = 0, time = Moment.now() - uploadStartTime 
      uploads.add(upload)

    let
      uploadFinishedByTimeout = allFutures(uploads).withTimeout(upload_timeout)
      uploadAllFinished = allFutures(uploads)
    # info "uploaded to DHT", by = 0, pass, time = allFinished.duration
    uploadFinishedByTimeout.addCallback proc(udata: pointer) =
      info "uploaded to DHT by timeout", by = 0, time = uploadFinishedByTimeout.duration
    uploadAllFinished.addCallback proc(udata: pointer) =
      info "uploaded to DHT all", by = 0, time = uploadAllFinished.duration

    await sleepAsync(sampling_delay)

    # sample
    proc sampleOne(sampler: discv5_protocol.Protocol, cid: NodeId, startdelay: Duration = 0.milliseconds) : Future[DiscResult[seq[byte]]] {.async.} =
      await sleepAsync(startdelay)
      return await sampler.findValue(cid)

    proc startSamplingDA(n: discv5_protocol.Protocol): (seq[int], seq[Future[DiscResult[seq[byte]]]]) =
      ## Generate random sample and start the sampling process
      var futs = newSeq[Future[DiscResult[seq[byte]]]]()

      let sample = sample(0 ..< blocksize, samplesize)
      debug "starting sampling", by = n, sample
      for s in sample:
        let fut = n.sampleOne(segmentIDs[s])
        futs.add(fut)
      return (sample, futs)

    proc sampleDA(n: discv5_protocol.Protocol): Future[(bool, int, Duration)] {.async.} =
      ## Sample and return detailed results of sampling
      let startTime = Moment.now()
      var (sample, futs) = startSamplingDA(n)

      # test is passed if all segments are retrieved in time
      discard await allFutures(futs).withTimeout(sampling_timeout)
      var passcount: int
      for i in 0 ..< futs.len:
        if futs[i].finished() and isOk(await futs[i]):
          passcount += 1
        else:
          info "sample failed", by = n.localNode, s = sample[i], key = segmentIDs[sample[i]]


      let
        time = Moment.now() - startTime
        pass = (passcount >= samplethreshold)
      info "sample", by = n.localNode, pass, cnt = passcount, time
      return (pass, passcount, time)

    # all nodes start sampling in parallel
    var samplings = newSeq[Future[(bool, int, Duration)]]()
    for n in 1 ..< nodecount:
      samplings.add(sampleDA(nodes[n][0]))
    await allFutures(samplings)

    # print statistics
    var
      passed = 0
    for f in samplings:
      if f.finished():
        let (pass, passcount, time) = await f
        passed += pass.int
        debug "sampleStats", pass, cnt = passcount, time
      else:
        error "This should not happen!"
    info "sampleStats", passed, total = samplings.len, ratio = passed/samplings.len

  waitfor main()

# proc teardownAll() =
#     for (n, _) in nodes: # if last test is enabled, we need nodes[1..^1] here
#       await n.closeWait()


