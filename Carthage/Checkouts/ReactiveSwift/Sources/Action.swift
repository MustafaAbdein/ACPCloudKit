import Foundation
import enum Result.NoError

/// Represents an action that will do some work when executed with a value of
/// type `Input`, then return zero or more values of type `Output` and/or fail
/// with an error of type `Error`. If no failure should be possible, NoError can
/// be specified for the `Error` parameter.
///
/// Actions enforce serial execution. Any attempt to execute an action multiple
/// times concurrently will return an error.
public final class Action<Input, Output, Error: Swift.Error> {
	private let executeClosure: (Input) -> SignalProducer<Output, Error>
	private let eventsObserver: Signal<Event<Output, Error>, NoError>.Observer

	/// A signal of all events generated from applications of the Action.
	///
	/// In other words, this will send every `Event` from every signal generated
	/// by each SignalProducer returned from apply().
	public let events: Signal<Event<Output, Error>, NoError>

	/// A signal of all values generated from applications of the Action.
	///
	/// In other words, this will send every value from every signal generated
	/// by each SignalProducer returned from apply().
	public let values: Signal<Output, NoError>

	/// A signal of all errors generated from applications of the Action.
	///
	/// In other words, this will send errors from every signal generated by
	/// each SignalProducer returned from apply().
	public let errors: Signal<Error, NoError>

	/// Whether the action is currently executing.
	public var isExecuting: Property<Bool> {
		return Property(_isExecuting)
	}

	private let _isExecuting: MutableProperty<Bool> = MutableProperty(false)

	/// Whether the action is currently enabled.
	public var isEnabled: Property<Bool> {
		return Property(_isEnabled)
	}

	private let _isEnabled: MutableProperty<Bool> = MutableProperty(false)

	/// Whether the instantiator of this action wants it to be enabled.
	private let isUserEnabled: Property<Bool>

	/// This queue is used for read-modify-write operations on the `_executing`
	/// property.
	private let executingQueue = DispatchQueue(
		label: "org.reactivecocoa.ReactiveSwift.Action.executingQueue",
		attributes: []
	)

	/// Whether the action should be enabled for the given combination of user
	/// enabledness and executing status.
	private static func shouldBeEnabled(userEnabled: Bool, executing: Bool) -> Bool {
		return userEnabled && !executing
	}

	/// Initializes an action that will be conditionally enabled, and creates a
	/// SignalProducer for each input.
	///
	/// - parameters:
	///   - enabledIf: Boolean property that shows whether the action is
	///                enabled.
	///   - execute: A closure that returns the signal producer returned by
	///              calling `apply(Input)` on the action.
	public init<P: PropertyProtocol>(enabledIf property: P, _ execute: @escaping (Input) -> SignalProducer<Output, Error>) where P.Value == Bool {
		executeClosure = execute
		isUserEnabled = Property(property)

		(events, eventsObserver) = Signal<Event<Output, Error>, NoError>.pipe()

		values = events.map { $0.value }.skipNil()
		errors = events.map { $0.error }.skipNil()

		_isEnabled <~ property.producer
			.combineLatest(with: isExecuting.producer)
			.map(Action.shouldBeEnabled)
	}

	/// Initializes an action that will be enabled by default, and creates a
	/// SignalProducer for each input.
	///
	/// - parameters:
	///   - execute: A closure that returns the signal producer returned by
	///              calling `apply(Input)` on the action.
	public convenience init(_ execute: @escaping (Input) -> SignalProducer<Output, Error>) {
		self.init(enabledIf: Property(value: true), execute)
	}

	deinit {
		eventsObserver.sendCompleted()
	}

	/// Creates a SignalProducer that, when started, will execute the action
	/// with the given input, then forward the results upon the produced Signal.
	///
	/// - note: If the action is disabled when the returned SignalProducer is
	///         started, the produced signal will send `ActionError.disabled`,
	///         and nothing will be sent upon `values` or `errors` for that
	///         particular signal.
	///
	/// - parameters:
	///   - input: A value that will be passed to the closure creating the signal
	///            producer.
	public func apply(_ input: Input) -> SignalProducer<Output, ActionError<Error>> {
		return SignalProducer { observer, disposable in
			var startedExecuting = false

			self.executingQueue.sync {
				if self._isEnabled.value {
					self._isExecuting.value = true
					startedExecuting = true
				}
			}

			if !startedExecuting {
				observer.send(error: .disabled)
				return
			}

			self.executeClosure(input).startWithSignal { signal, signalDisposable in
				disposable += signalDisposable

				signal.observe { event in
					observer.action(event.mapError(ActionError.producerFailed))
					self.eventsObserver.send(value: event)
				}
			}

			disposable += {
				self._isExecuting.value = false
			}
		}
	}
}

public protocol ActionProtocol {
	/// The type of argument to apply the action to.
	associatedtype Input
	/// The type of values returned by the action.
	associatedtype Output
	/// The type of error when the action fails. If errors aren't possible then
	/// `NoError` can be used.
	associatedtype Error: Swift.Error

	/// Whether the action is currently enabled.
	var isEnabled: Property<Bool> { get }

	/// Extracts an action from the receiver.
	var action: Action<Input, Output, Error> { get }

	/// Creates a SignalProducer that, when started, will execute the action
	/// with the given input, then forward the results upon the produced Signal.
	///
	/// - note: If the action is disabled when the returned SignalProducer is
	///         started, the produced signal will send `ActionError.disabled`,
	///         and nothing will be sent upon `values` or `errors` for that
	///         particular signal.
	///
	/// - parameters:
	///   - input: A value that will be passed to the closure creating the signal
	///            producer.
	func apply(_ input: Input) -> SignalProducer<Output, ActionError<Error>>
}

extension Action: ActionProtocol {
	public var action: Action {
		return self
	}
}

/// The type of error that can occur from Action.apply, where `Error` is the
/// type of error that can be generated by the specific Action instance.
public enum ActionError<Error: Swift.Error>: Swift.Error {
	/// The producer returned from apply() was started while the Action was
	/// disabled.
	case disabled

	/// The producer returned from apply() sent the given error.
	case producerFailed(Error)
}

public func == <Error: Equatable>(lhs: ActionError<Error>, rhs: ActionError<Error>) -> Bool {
	switch (lhs, rhs) {
	case (.disabled, .disabled):
		return true

	case let (.producerFailed(left), .producerFailed(right)):
		return left == right

	default:
		return false
	}
}
