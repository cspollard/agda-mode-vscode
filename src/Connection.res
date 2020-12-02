open Belt

module Error = {
  type t =
    | PathSearch(Process.PathSearch.Error.t)
    | Validation(Process.Validation.Error.t)
    | Process(Process.Error.t)
  let toString = x =>
    switch x {
    | PathSearch(e) => Process.PathSearch.Error.toString(e)
    | Validation(e) => Process.Validation.Error.toString(e)
    | Process(e) => Process.Error.toString(e)
    }
}

@bs.module external untildify: string => string = "untildify"

module Metadata = {
  // supported protocol
  // p.s. currently only the `EmacsOnly` kind is supported
  module Protocol = {
    type t =
      | EmacsOnly
      | EmacsAndJSON
    let toString = x =>
      switch x {
      | EmacsOnly => "Emacs"
      | EmacsAndJSON => "Emacs / JSON"
      }
  }

  type t = {
    path: string,
    args: array<string>,
    version: string,
    protocol: Protocol.t,
  }

  // for making error report
  let toString = self => {
    let path = "* path: " ++ self.path
    let args = "* args: " ++ Util.Pretty.array(self.args)
    let version = "* version: " ++ self.version
    let protocol = "* protocol: " ++ Protocol.toString(self.protocol)
    let os = "* platform: " ++ N.OS.type_()

    "## Parse Log" ++
    ("\n" ++
    (path ++
    ("\n" ++
    (args ++ ("\n" ++ (version ++ ("\n" ++ (protocol ++ ("\n" ++ (os ++ "\n"))))))))))
  }

  // a more sophiscated "make"
  let make = (path, args): Promise.t<result<t, Error.t>> => {
    let validator = (output): result<(string, Protocol.t), string> =>
      switch Js.String.match_(%re("/Agda version (.*)/"), output) {
      | None => Error("Cannot read Agda version")
      | Some(match_) =>
        switch match_[1] {
        | None => Error("Cannot read Agda version")
        | Some(version) =>
          Ok((
            version,
            Js.Re.test_(%re("/--interaction-json/"), output)
              ? Protocol.EmacsAndJSON
              : Protocol.EmacsOnly,
          ))
        }
      }
    // normailize the path by replacing the tild "~/" with the absolute path of home directory
    let path = untildify(path)
    Process.Validation.run("\"" ++ (path ++ "\" -V"), validator)->Promise.mapOk(((
      version,
      protocol,
    )) => {
      path: path,
      args: args,
      version: version,
      protocol: protocol,
    })->Promise.mapError(e => Error.Validation(e))
  }
}

type response = Parser.Incr.Gen.t<result<Response.Prioritized.t, Parser.Error.t>>

type t = {
  metadata: Metadata.t,
  process: Process.t,
  chan: Chan.t<result<response, Error.t>>,
  mutable encountedFirstPrompt: bool,
}

let destroy = self => {
  self.process.disconnect() |> ignore
  self.chan->Chan.destroy
  self.encountedFirstPrompt = false
}

let wire = (self): unit => {
  // We use the prompt "Agda2>" as the delimiter of the end of a response
  // However, the prompt "Agda2>" also appears at the very start of the conversation
  // So this would be what it looks like:
  //    >>> request
  //      stop          <------- wierd stop
  //      yield
  //      yield
  //      stop
  //    >> request
  //      yield
  //      yield
  //      stop

  let toResponse = Parser.Incr.Gen.flatMap(x =>
    switch x {
    | Error(parseError) => Parser.Incr.Gen.Yield(Error(parseError))
    | Ok(Parser.SExpression.A("Agda2>")) => Parser.Incr.Gen.Stop
    | Ok(tokens) => Parser.Incr.Gen.Yield(Response.Prioritized.parse(tokens))
    }
  )

  // resolves the requests in the queue
  let handleResponse = (res: response) =>
    switch res {
    | Yield(x) => self.chan->Chan.emit(Ok(Yield(x)))
    | Stop =>
      if self.encountedFirstPrompt {
        self.chan->Chan.emit(Ok(Stop))
      } else {
        // do nothing when encountering the first Stop
        self.encountedFirstPrompt = true
      }
    }

  let mapError = x => Parser.Incr.Gen.map(x =>
      switch x {
      | Ok(x) => Ok(x)
      | Error((no, e)) => Error(Parser.Error.SExpression(no, e))
      }
    , x)

  let pipeline = Parser.SExpression.makeIncr(x => x->mapError->toResponse->handleResponse)

  // listens to the "data" event on the stdout
  // The chunk may contain various fractions of the Agda output
  let onData: Process.output => unit = x =>
    switch x {
    | Stdout(rawText) =>
      // split the raw text into pieces and feed it to the parser
      rawText->Parser.split->Array.forEach(Parser.Incr.feed(pipeline))
    | Stderr(_) => ()
    | Error(e) => self.chan->Chan.emit(Error(Process(e)))
    }

  let _ = self.process.chan->Chan.on(onData)
}

let make = (fromConfig, toConfig) => {
  // first, get the path from the config (stored in the Editor)
  // if there's no stored path, find one from the OS
  let getPath = (): Promise.t<result<string, Error.t>> => {
    let storedPath = fromConfig()->Option.mapWithDefault("", Js.String.trim)
    if storedPath == "" || storedPath == "." {
      Process.PathSearch.run("agda")
      ->Promise.mapOk(Js.String.trim)
      ->Promise.mapError(e => Error.PathSearch(e))
    } else {
      Promise.resolved(Ok(storedPath))
    }
  }

  // store the path in the editor config
  let setPath = (path): unit => toConfig(path)->ignore

  let args = ["--interaction"]

  getPath()
  ->Promise.flatMapOk(path => Metadata.make(path, args))
  ->Promise.tapOk(metadata => setPath(metadata.path))
  ->Promise.mapOk(metadata => {
    metadata: metadata,
    process: Process.make(metadata.path, metadata.args),
    chan: Chan.make(),
    encountedFirstPrompt: false,
  })
  ->Promise.tapOk(wire)
}

let send = (request, self): unit => self.process.send(request)->ignore