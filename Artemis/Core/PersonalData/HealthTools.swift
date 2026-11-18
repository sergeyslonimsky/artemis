import Foundation
import FoundationModels
import HealthKit

/// Read-only HealthKit summaries for the on-device model. HealthKit doesn't say whether reading
/// was denied, so "no data" may also mean "no access".
actor HealthStore {
    static let shared = HealthStore()

    enum Metric: String, Sendable {
        case steps, distance, activeEnergy, sleep, heartRate, restingHeartRate, workouts, weight
    }

    private let store = HKHealthStore()
    private var requestedAccess = false

    private static let readTypes: Set<HKObjectType> = [
        HKQuantityType(.stepCount),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.heartRate),
        HKQuantityType(.restingHeartRate),
        HKQuantityType(.bodyMass),
        HKCategoryType(.sleepAnalysis),
        HKObjectType.workoutType(),
    ]

    func summary(of metric: Metric, days: Int) async throws -> String {
        guard HKHealthStore.isHealthDataAvailable() else { return "Health data isn't available on this device." }
        if !requestedAccess {
            try await store.requestAuthorization(toShare: [], read: Self.readTypes)
            requestedAccess = true
        }
        let calendar = Calendar.current
        let end = Date()
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: end)) ?? end

        switch metric {
        case .steps:
            return try await daily(.stepCount, unit: .count(), options: .cumulativeSum, from: start, to: end) {
                "\(Int($0)) steps"
            }
        case .distance:
            return try await daily(.distanceWalkingRunning, unit: .meter(), options: .cumulativeSum, from: start, to: end) {
                Measurement(value: $0, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
            }
        case .activeEnergy:
            return try await daily(.activeEnergyBurned, unit: .kilocalorie(), options: .cumulativeSum, from: start, to: end) {
                "\(Int($0)) kcal"
            }
        case .heartRate:
            return try await daily(.heartRate, unit: .count().unitDivided(by: .minute()), options: .discreteAverage, from: start, to: end) {
                "average \(Int($0)) bpm"
            }
        case .restingHeartRate:
            return try await daily(.restingHeartRate, unit: .count().unitDivided(by: .minute()), options: .discreteAverage, from: start, to: end) {
                "\(Int($0)) bpm"
            }
        case .weight:
            return try await latestWeight()
        case .sleep:
            return try await sleep(from: start, to: end)
        case .workouts:
            return try await workouts(from: start, to: end)
        }
    }

    private func daily(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        options: HKStatisticsOptions,
        from start: Date,
        to end: Date,
        format: (Double) -> String
    ) async throws -> String {
        let type = HKQuantityType(identifier)
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: HKSamplePredicate.quantitySample(type: type, predicate: HKQuery.predicateForSamples(withStart: start, end: end)),
            options: options,
            anchorDate: Calendar.current.startOfDay(for: start),
            intervalComponents: DateComponents(day: 1)
        )
        let collection = try await descriptor.result(for: store)
        let lines = collection.statistics().compactMap { statistics -> String? in
            let quantity = options.contains(.cumulativeSum) ? statistics.sumQuantity() : statistics.averageQuantity()
            guard let value = quantity?.doubleValue(for: unit) else { return nil }
            return "- \(Self.day(statistics.startDate)): \(format(value))"
        }
        return lines.isEmpty ? Self.noData : lines.joined(separator: "\n")
    }

    /// Time asleep per night (attributed to the day the user woke up). Watch and iPhone often
    /// both record sleep, so overlapping intervals are merged instead of summed.
    private func sleep(from start: Date, to end: Date) async throws -> String {
        // Nights that ended on the first day began the evening before.
        let queryStart = start.addingTimeInterval(-12 * 3600)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: HKQuery.predicateForSamples(withStart: queryStart, end: end))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let asleepValues = HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue)
        let samples = try await descriptor.result(for: store).filter { asleepValues.contains($0.value) }
        guard !samples.isEmpty else { return Self.noData }

        var nights: [Date: [(Date, Date)]] = [:]
        for sample in samples {
            nights[Calendar.current.startOfDay(for: sample.endDate), default: []].append((sample.startDate, sample.endDate))
        }
        return nights.keys.sorted().filter { $0 >= start }.map { night in
            let intervals = nights[night, default: []].sorted { $0.0 < $1.0 }
            var total: TimeInterval = 0
            var current: (Date, Date)?
            for interval in intervals {
                if let open = current, interval.0 <= open.1 {
                    current = (open.0, max(open.1, interval.1))
                } else {
                    if let open = current { total += open.1.timeIntervalSince(open.0) }
                    current = interval
                }
            }
            if let open = current { total += open.1.timeIntervalSince(open.0) }
            let bedtime = intervals.first.map { $0.0.formatted(date: .omitted, time: .shortened) } ?? ""
            let wake = intervals.map(\.1).max().map { $0.formatted(date: .omitted, time: .shortened) } ?? ""
            return "- \(Self.day(night)): \(Self.duration(total)) asleep (\(bedtime)–\(wake))"
        }.joined(separator: "\n")
    }

    private func workouts(from start: Date, to end: Date) async throws -> String {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForSamples(withStart: start, end: end))],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: 20
        )
        let workouts = try await descriptor.result(for: store)
        guard !workouts.isEmpty else { return "No workouts in this period." }
        return workouts.map { workout in
            var line = "- \(Self.day(workout.startDate)) \(workout.startDate.formatted(date: .omitted, time: .shortened)): "
                + "\(Self.name(of: workout.workoutActivityType)), \(Self.duration(workout.duration))"
            if let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()) {
                line += ", \(Int(energy)) kcal"
            }
            return line
        }.joined(separator: "\n")
    }

    private func latestWeight() async throws -> String {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.bodyMass))],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: 1
        )
        guard let sample = try await descriptor.result(for: store).first else { return Self.noData }
        let mass = Measurement(value: sample.quantity.doubleValue(for: .gramUnit(with: .kilo)), unit: UnitMass.kilograms)
        return "Latest weight: \(mass.formatted(.measurement(width: .abbreviated, usage: .personWeight))) on \(Self.day(sample.startDate))."
    }

    private static let noData = "No data for this period (or Artemis can't read it: check Health › Sharing › Apps)."

    private static func day(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private static func duration(_ interval: TimeInterval) -> String {
        Duration.seconds(interval).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    private static func name(of type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: "Running"
        case .walking: "Walking"
        case .cycling: "Cycling"
        case .swimming: "Swimming"
        case .hiking: "Hiking"
        case .yoga: "Yoga"
        case .functionalStrengthTraining, .traditionalStrengthTraining: "Strength training"
        case .highIntensityIntervalTraining: "HIIT"
        case .elliptical: "Elliptical"
        case .rowing: "Rowing"
        case .dance: "Dance"
        case .pilates: "Pilates"
        case .tennis: "Tennis"
        case .soccer: "Football"
        default: "Workout"
        }
    }
}

struct HealthDataTool: Tool {
    let sink: ToolEventSink

    let name = "getHealthData"
    let description = "Reads the user's daily health and activity data from Apple Health."

    @Generable
    enum Metric {
        case steps
        case distance
        case activeEnergy
        case sleep
        case heartRate
        case restingHeartRate
        case workouts
        case weight
    }

    @Generable
    struct Arguments {
        var metric: Metric
        @Guide(description: "Number of days back from today, including today, from 1 to 30")
        var days: Int
    }

    func call(arguments: Arguments) async throws -> String {
        sink.send(.started(.health))
        let metric: HealthStore.Metric = switch arguments.metric {
        case .steps: .steps
        case .distance: .distance
        case .activeEnergy: .activeEnergy
        case .sleep: .sleep
        case .heartRate: .heartRate
        case .restingHeartRate: .restingHeartRate
        case .workouts: .workouts
        case .weight: .weight
        }
        do {
            return try await HealthStore.shared.summary(of: metric, days: min(max(arguments.days, 1), 30))
        } catch {
            return "Couldn't read health data: \(error.localizedDescription)"
        }
    }
}
