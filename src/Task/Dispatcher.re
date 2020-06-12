open Belt;

module Impl = (Editor: Sig.Editor) => {
  module ErrorHandler = Handle__Error.Impl(Editor);
  // module ViewHandler = Handle__View.Impl(Editor);

  // module GoalHandler = Handle__Goal.Impl(Editor);
  module ResponseHandler = Handle__Response.Impl(Editor);
  module Task = Task.Impl(Editor);
  // module State = State.Impl(Editor);
  // module Request = Request.Impl(Editor);
  // type t = Runner.t(Command.t);
  open! Task;

  type status('a) =
    | Occupied(array('a))
    | Available;

  type t = {
    agdaRequestRunner: Runner2.t(Request.t),
    mutable agdaRequestStatus: status(Request.t),
    viewRequestRunner: Runner2.t(View.Request.t),
    mutable viewRequestStatus: status(Request.t),
    otherTaskRunner: Runner2.t(Task.t),
  };

  let dispatchCommand = (self, command) => {
    module CommandHandler = Handle__Command.Impl(Editor);
    let tasks = CommandHandler.handle(command)->List.toArray;
    self.otherTaskRunner->Runner2.pushMany(tasks);
  };

  let sendAgdaRequest = (runTasks, state, req) => {
    // this promise get resolved after the request to Agda is completed
    let (promise, resolve) = Promise.pending();
    let handle = ref(None);
    let handler: result(Connection.response, Connection.Error.t) => unit =
      fun
      | Error(error) => {
          let tasks =
            ErrorHandler.handle(Error.Connection(error))->List.toArray;
          runTasks(tasks)->Promise.get(resolve);
        }
      | Ok(Parser.Incr.Event.Yield(Error(error))) => {
          let tasks = ErrorHandler.handle(Error.Parser(error))->List.toArray;
          runTasks(tasks)->Promise.get(resolve);
        }
      | Ok(Yield(Ok(response))) => {
          let tasks = ResponseHandler.handle(response)->List.toArray;
          runTasks(tasks)->ignore;
        }
      | Ok(Stop) => resolve();

    state
    ->State.sendRequestToAgda(req)
    ->Promise.flatMap(
        fun
        | Ok(connection) => {
            handle := Some(connection.Connection.emitter.on(handler));
            promise;
          }
        | Error(error) => {
            let tasks = ErrorHandler.handle(error)->List.toArray;
            runTasks(tasks)->Promise.get(resolve);
            promise;
          },
      )
    ->Promise.tap(() => (handle^)->Option.forEach(f => f()));
  };

  let make = state => {
    let self = {
      agdaRequestRunner: Runner2.make(),
      agdaRequestStatus: Available,
      viewRequestRunner: Runner2.make(),
      viewRequestStatus: Available,
      otherTaskRunner: Runner2.make(),
    };

    self.otherTaskRunner
    ->Runner2.setup(task => {
        switch (task) {
        | SendRequest(req) =>
          let runTasks = tasks => {
            self.otherTaskRunner->Runner2.pushMany(tasks);
          };
          switch (self.agdaRequestStatus) {
          | Occupied(reqs) =>
            Js.Array.push(req, reqs)->ignore;
            Promise.resolved();
          | Available =>
            self.agdaRequestStatus = Occupied([||]);
            sendAgdaRequest(runTasks, state, req)
            ->Promise.flatMap(() => {
                let reqs =
                  switch (self.agdaRequestStatus) {
                  | Occupied(reqs) => reqs
                  | Available => [||]
                  };
                self.agdaRequestStatus = Available;
                self.agdaRequestRunner->Runner2.pushManyToFront(reqs);
              });
          };
        | others => Promise.resolved()
        }
      });

    self;
  };
};