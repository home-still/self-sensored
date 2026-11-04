import CryptoKit
import Foundation
import HealthKit

// MARK: - Health Sample Payload

/// Codable struct matching the API's expected JSON schema for health samples.
struct HealthSamplePayload: Codable, Sendable {
    let hkUuid: String
    let sampleType: String
    let contentHash: String
    let sourceName: String?
    let sourceBundleId: String?
    let sourceDeviceId: UUID?
    let startDate: Date
    let endDate: Date
    let quantityValue: Double?
    let quantityUnit: String?
    let categoryValue: Int?
    let metadata: [String: String]?

    enum CodingKeys: String, CodingKey {
        case hkUuid = "hk_uuid"
        case sampleType = "sample_type"
        case contentHash = "content_hash"
        case sourceName = "source_name"
        case sourceBundleId = "source_bundle_id"
        case sourceDeviceId = "source_device_id"
        case startDate = "start_date"
        case endDate = "end_date"
        case quantityValue = "quantity_value"
        case quantityUnit = "quantity_unit"
        case categoryValue = "category_value"
        case metadata
    }

    /// Compute a SHA-256 content hash from the canonical fields.
    static func computeContentHash(
        sampleType: String,
        startDate: Date,
        endDate: Date,
        quantityValue: Double?,
        quantityUnit: String?,
        categoryValue: Int?,
        metadata: [String: String]?
    ) -> String {
        var parts = [sampleType, startDate.iso8601String, endDate.iso8601String]
        if let qv = quantityValue { parts.append(String(qv)) }
        if let qu = quantityUnit { parts.append(qu) }
        if let cv = categoryValue { parts.append(String(cv)) }
        if let meta = metadata {
            for key in meta.keys.sorted() { parts.append("\(key)=\(meta[key]!)") }
        }
        let canonical = parts.joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Workout Payload

/// Codable struct matching the API's expected JSON schema for workouts.
struct WorkoutPayload: Codable, Sendable {
    let hkUuid: String
    let activityType: Int
    let activityName: String?
    let durationSeconds: Double?
    let totalEnergyBurnedKcal: Double?
    let totalDistanceM: Double?
    let totalSwimmingStrokeCount: Int?
    let contentHash: String
    let startDate: Date
    let endDate: Date
    let sourceDeviceId: UUID?
    let metadata: [String: String]?

    enum CodingKeys: String, CodingKey {
        case hkUuid = "hk_uuid"
        case activityType = "activity_type"
        case activityName = "activity_name"
        case durationSeconds = "duration_seconds"
        case totalEnergyBurnedKcal = "total_energy_burned_kcal"
        case totalDistanceM = "total_distance_m"
        case totalSwimmingStrokeCount = "total_swimming_stroke_count"
        case contentHash = "content_hash"
        case startDate = "start_date"
        case endDate = "end_date"
        case sourceDeviceId = "source_device_id"
        case metadata
    }

    /// Compute a SHA-256 content hash from the canonical fields.
    static func computeContentHash(
        activityType: Int,
        startDate: Date,
        endDate: Date,
        durationSeconds: Double?,
        totalEnergyBurnedKcal: Double?,
        totalDistanceM: Double?,
        metadata: [String: String]?
    ) -> String {
        var parts = [String(activityType), startDate.iso8601String, endDate.iso8601String]
        if let d = durationSeconds { parts.append(String(d)) }
        if let e = totalEnergyBurnedKcal { parts.append(String(e)) }
        if let dist = totalDistanceM { parts.append(String(dist)) }
        if let meta = metadata {
            for key in meta.keys.sorted() { parts.append("\(key)=\(meta[key]!)") }
        }
        let canonical = parts.joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Hash Check Types

struct HashCheckItem: Codable, Sendable {
    let hkUuid: String
    let contentHash: String

    enum CodingKeys: String, CodingKey {
        case hkUuid = "hk_uuid"
        case contentHash = "content_hash"
    }
}

struct HashCheckRequest: Codable, Sendable {
    let deviceId: UUID
    let sampleType: String
    let items: [HashCheckItem]

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case sampleType = "sample_type"
        case items
    }
}

struct HashCheckResponse: Codable, Sendable {
    let neededUuids: [String]
    let sessionId: Int64

    enum CodingKeys: String, CodingKey {
        case neededUuids = "needed_uuids"
        case sessionId = "session_id"
    }
}

// MARK: - Sync Payload (two-phase protocol)

/// The payload sent to POST /api/v1/health/sync
struct SyncPayload: Codable, Sendable {
    let sessionId: Int64
    let deviceId: UUID
    let sampleType: String
    var location: Location?
    var samples: [HealthSamplePayload] = []
    var workouts: [WorkoutPayload] = []
    var deletedUuids: [String] = []

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case deviceId = "device_id"
        case sampleType = "sample_type"
        case location
        case samples
        case workouts
        case deletedUuids = "deleted_uuids"
    }
}

struct SyncResponse: Codable, Sendable {
    let samplesSynced: Int
    let workoutsSynced: Int
    let deleted: Int

    enum CodingKeys: String, CodingKey {
        case samplesSynced = "samples_synced"
        case workoutsSynced = "workouts_synced"
        case deleted
    }
}

// MARK: - Location

struct Location: Codable, Sendable {
    let latitude: Double
    let longitude: Double
}

// MARK: - Device Registration

struct DeviceRegistration: Codable, Sendable {
    let identifierForVendor: String
    let deviceName: String?
    let deviceModel: String?
    let systemName: String?
    let systemVersion: String?
    let appVersion: String?
    let watchModel: String?
    let watchOsVersion: String?

    enum CodingKeys: String, CodingKey {
        case identifierForVendor = "identifier_for_vendor"
        case deviceName = "device_name"
        case deviceModel = "device_model"
        case systemName = "system_name"
        case systemVersion = "system_version"
        case appVersion = "app_version"
        case watchModel = "watch_model"
        case watchOsVersion = "watch_os_version"
    }
}

struct DeviceResponse: Codable, Sendable {
    let deviceId: UUID

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
    }
}

// MARK: - Delete Request

struct DeleteRequest: Codable, Sendable {
    let hkUuids: [String]

    enum CodingKeys: String, CodingKey {
        case hkUuids = "hk_uuids"
    }
}

// MARK: - HKSample -> HealthSamplePayload conversion

extension HealthSamplePayload {
    init(from sample: HKSample, deviceId: UUID? = nil) {
        self.hkUuid = sample.uuid.uuidString
        self.sampleType = sample.sampleType.identifier
        self.sourceName = sample.sourceRevision.source.name
        self.sourceBundleId = sample.sourceRevision.source.bundleIdentifier
        self.sourceDeviceId = deviceId
        self.startDate = sample.startDate
        self.endDate = sample.endDate

        // Extract quantity value if applicable
        let qv: Double?
        let qu: String?
        if let quantitySample = sample as? HKQuantitySample {
            let unit = HKTypes.preferredUnit(for: quantitySample.quantityType)
            qv = quantitySample.quantity.doubleValue(for: unit)
            qu = unit.unitString
        } else {
            qv = nil
            qu = nil
        }
        self.quantityValue = qv
        self.quantityUnit = qu

        // Extract category value if applicable
        let cv: Int?
        if let categorySample = sample as? HKCategorySample {
            cv = categorySample.value
        } else {
            cv = nil
        }
        self.categoryValue = cv

        // Flatten metadata to string values
        let meta = sample.metadata?.compactMapValues { "\($0)" }
        self.metadata = meta

        // Compute content hash
        self.contentHash = HealthSamplePayload.computeContentHash(
            sampleType: self.sampleType,
            startDate: self.startDate,
            endDate: self.endDate,
            quantityValue: qv,
            quantityUnit: qu,
            categoryValue: cv,
            metadata: meta
        )
    }
}

extension WorkoutPayload {
    init(from workout: HKWorkout, deviceId: UUID? = nil) {
        self.hkUuid = workout.uuid.uuidString
        self.activityType = Int(workout.workoutActivityType.rawValue)
        self.activityName = workout.workoutActivityType.name
        self.durationSeconds = workout.duration
        self.totalEnergyBurnedKcal = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())
        self.totalDistanceM = workout.totalDistance?.doubleValue(for: .meter())
        self.totalSwimmingStrokeCount = workout.totalSwimmingStrokeCount.map { Int($0.doubleValue(for: .count())) }
        self.startDate = workout.startDate
        self.endDate = workout.endDate
        self.sourceDeviceId = deviceId
        let meta = workout.metadata?.compactMapValues { "\($0)" }
        self.metadata = meta

        // Compute content hash
        self.contentHash = WorkoutPayload.computeContentHash(
            activityType: self.activityType,
            startDate: self.startDate,
            endDate: self.endDate,
            durationSeconds: self.durationSeconds,
            totalEnergyBurnedKcal: self.totalEnergyBurnedKcal,
            totalDistanceM: self.totalDistanceM,
            metadata: meta
        )
    }
}

// MARK: - Helpers

extension HKTypes {
    /// Returns a sensible default unit for a quantity type.
    static func preferredUnit(for quantityType: HKQuantityType) -> HKUnit {
        switch quantityType.identifier {
        // Counts
        case HKQuantityTypeIdentifier.stepCount.rawValue,
             HKQuantityTypeIdentifier.flightsClimbed.rawValue,
             HKQuantityTypeIdentifier.numberOfAlcoholicBeverages.rawValue,
             HKQuantityTypeIdentifier.numberOfTimesFallen.rawValue,
             HKQuantityTypeIdentifier.pushCount.rawValue,
             HKQuantityTypeIdentifier.swimmingStrokeCount.rawValue,
             HKQuantityTypeIdentifier.nikeFuel.rawValue,
             HKQuantityTypeIdentifier.inhalerUsage.rawValue:
            return .count()

        // Heart rates (count/min)
        case HKQuantityTypeIdentifier.heartRate.rawValue,
             HKQuantityTypeIdentifier.restingHeartRate.rawValue,
             HKQuantityTypeIdentifier.walkingHeartRateAverage.rawValue:
            return HKUnit.count().unitDivided(by: .minute())

        // HRV
        case HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue:
            return .secondUnit(with: .milli)

        // Body mass
        case HKQuantityTypeIdentifier.bodyMass.rawValue,
             HKQuantityTypeIdentifier.leanBodyMass.rawValue:
            return .gramUnit(with: .kilo)

        // BMI (count, dimensionless)
        case HKQuantityTypeIdentifier.bodyMassIndex.rawValue:
            return .count()

        // Height
        case HKQuantityTypeIdentifier.height.rawValue:
            return .meterUnit(with: .centi)

        // Waist circumference
        case HKQuantityTypeIdentifier.waistCircumference.rawValue:
            return .meterUnit(with: .centi)

        // Percentages
        case HKQuantityTypeIdentifier.oxygenSaturation.rawValue,
             HKQuantityTypeIdentifier.bodyFatPercentage.rawValue,
             HKQuantityTypeIdentifier.peripheralPerfusionIndex.rawValue,
             HKQuantityTypeIdentifier.atrialFibrillationBurden.rawValue:
            return .percent()

        // Energy (kcal)
        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue,
             HKQuantityTypeIdentifier.basalEnergyBurned.rawValue,
             HKQuantityTypeIdentifier.dietaryEnergyConsumed.rawValue:
            return .kilocalorie()

        // Distance (meters)
        case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
             HKQuantityTypeIdentifier.distanceCycling.rawValue,
             HKQuantityTypeIdentifier.distanceSwimming.rawValue,
             HKQuantityTypeIdentifier.distanceWheelchair.rawValue,
             HKQuantityTypeIdentifier.distanceDownhillSnowSports.rawValue:
            return .meter()

        // Time (minutes)
        case HKQuantityTypeIdentifier.appleExerciseTime.rawValue,
             HKQuantityTypeIdentifier.appleMoveTime.rawValue,
             HKQuantityTypeIdentifier.appleStandTime.rawValue:
            return .minute()

        // Temperature
        case HKQuantityTypeIdentifier.bodyTemperature.rawValue,
             HKQuantityTypeIdentifier.basalBodyTemperature.rawValue,
             HKQuantityTypeIdentifier.appleSleepingWristTemperature.rawValue:
            return .degreeCelsius()

        // Respiratory rate (count/min)
        case HKQuantityTypeIdentifier.respiratoryRate.rawValue:
            return HKUnit.count().unitDivided(by: .minute())

        // Blood pressure (mmHg)
        case HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue,
             HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue:
            return .millimeterOfMercury()

        // Blood glucose
        case HKQuantityTypeIdentifier.bloodGlucose.rawValue:
            return HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))

        // VO2 Max (mL/(kg*min))
        case HKQuantityTypeIdentifier.vo2Max.rawValue:
            return HKUnit.literUnit(with: .milli)
                .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))

        // Audio exposure (dB)
        case HKQuantityTypeIdentifier.environmentalAudioExposure.rawValue,
             HKQuantityTypeIdentifier.headphoneAudioExposure.rawValue,
             HKQuantityTypeIdentifier.environmentalSoundReduction.rawValue:
            return .decibelAWeightedSoundPressureLevel()

        // UV exposure
        case HKQuantityTypeIdentifier.uvExposure.rawValue:
            return .count()

        // Speed (m/s)
        case HKQuantityTypeIdentifier.walkingSpeed.rawValue,
             HKQuantityTypeIdentifier.stairAscentSpeed.rawValue,
             HKQuantityTypeIdentifier.stairDescentSpeed.rawValue,
             HKQuantityTypeIdentifier.runningSpeed.rawValue:
            return .meter().unitDivided(by: .second())

        // Walking metrics
        case HKQuantityTypeIdentifier.walkingStepLength.rawValue,
             HKQuantityTypeIdentifier.runningStrideLength.rawValue:
            return .meterUnit(with: .centi)

        case HKQuantityTypeIdentifier.walkingDoubleSupportPercentage.rawValue,
             HKQuantityTypeIdentifier.walkingAsymmetryPercentage.rawValue:
            return .percent()

        // Six-minute walk test distance
        case HKQuantityTypeIdentifier.sixMinuteWalkTestDistance.rawValue:
            return .meter()

        // Running metrics
        case HKQuantityTypeIdentifier.runningPower.rawValue:
            return .watt()

        case HKQuantityTypeIdentifier.runningGroundContactTime.rawValue:
            return .secondUnit(with: .milli)

        case HKQuantityTypeIdentifier.runningVerticalOscillation.rawValue:
            return .meterUnit(with: .centi)

        // Cycling metrics
        case HKQuantityTypeIdentifier.cyclingSpeed.rawValue:
            return .meter().unitDivided(by: .second())

        case HKQuantityTypeIdentifier.cyclingPower.rawValue:
            return .watt()

        case HKQuantityTypeIdentifier.cyclingCadence.rawValue:
            return HKUnit.count().unitDivided(by: .minute())

        case HKQuantityTypeIdentifier.cyclingFunctionalThresholdPower.rawValue:
            return .watt()

        // Lung function
        case HKQuantityTypeIdentifier.forcedExpiratoryVolume1.rawValue,
             HKQuantityTypeIdentifier.forcedVitalCapacity.rawValue:
            return .liter()

        case HKQuantityTypeIdentifier.peakExpiratoryFlowRate.rawValue:
            return .liter().unitDivided(by: .minute())

        // Insulin
        case HKQuantityTypeIdentifier.insulinDelivery.rawValue:
            return .internationalUnit()

        // Water
        case HKQuantityTypeIdentifier.dietaryWater.rawValue:
            return .liter()

        // Dietary nutrients (grams)
        case HKQuantityTypeIdentifier.dietaryProtein.rawValue,
             HKQuantityTypeIdentifier.dietaryCarbohydrates.rawValue,
             HKQuantityTypeIdentifier.dietaryFatTotal.rawValue,
             HKQuantityTypeIdentifier.dietaryFiber.rawValue,
             HKQuantityTypeIdentifier.dietarySugar.rawValue,
             HKQuantityTypeIdentifier.dietaryFatSaturated.rawValue,
             HKQuantityTypeIdentifier.dietaryFatMonounsaturated.rawValue,
             HKQuantityTypeIdentifier.dietaryFatPolyunsaturated.rawValue,
             HKQuantityTypeIdentifier.dietaryCholesterol.rawValue:
            return .gram()

        // Dietary minerals & vitamins (milligrams)
        case HKQuantityTypeIdentifier.dietaryCaffeine.rawValue,
             HKQuantityTypeIdentifier.dietaryCalcium.rawValue,
             HKQuantityTypeIdentifier.dietaryIron.rawValue,
             HKQuantityTypeIdentifier.dietaryPotassium.rawValue,
             HKQuantityTypeIdentifier.dietarySodium.rawValue,
             HKQuantityTypeIdentifier.dietaryZinc.rawValue,
             HKQuantityTypeIdentifier.dietaryMagnesium.rawValue,
             HKQuantityTypeIdentifier.dietaryManganese.rawValue,
             HKQuantityTypeIdentifier.dietaryPhosphorus.rawValue,
             HKQuantityTypeIdentifier.dietaryCopper.rawValue,
             HKQuantityTypeIdentifier.dietaryNiacin.rawValue,
             HKQuantityTypeIdentifier.dietaryPantothenicAcid.rawValue,
             HKQuantityTypeIdentifier.dietaryRiboflavin.rawValue,
             HKQuantityTypeIdentifier.dietaryThiamin.rawValue,
             HKQuantityTypeIdentifier.dietaryVitaminB6.rawValue,
             HKQuantityTypeIdentifier.dietaryVitaminC.rawValue,
             HKQuantityTypeIdentifier.dietaryVitaminE.rawValue:
            return .gramUnit(with: .milli)

        // Dietary micro (micrograms)
        case HKQuantityTypeIdentifier.dietaryBiotin.rawValue,
             HKQuantityTypeIdentifier.dietaryChromium.rawValue,
             HKQuantityTypeIdentifier.dietaryFolate.rawValue,
             HKQuantityTypeIdentifier.dietaryIodine.rawValue,
             HKQuantityTypeIdentifier.dietaryMolybdenum.rawValue,
             HKQuantityTypeIdentifier.dietarySelenium.rawValue,
             HKQuantityTypeIdentifier.dietaryVitaminA.rawValue,
             HKQuantityTypeIdentifier.dietaryVitaminB12.rawValue,
             HKQuantityTypeIdentifier.dietaryVitaminD.rawValue,
             HKQuantityTypeIdentifier.dietaryVitaminK.rawValue:
            return HKUnit.gramUnit(with: .micro)

        // Electrodermal activity (microsiemens)
        case HKQuantityTypeIdentifier.electrodermalActivity.rawValue:
            return HKUnit(from: "mcS")

        default:
            return .count()
        }
    }
}

extension HKWorkoutActivityType {
    var name: String {
        switch self {
        case .running: return "Running"
        case .cycling: return "Cycling"
        case .walking: return "Walking"
        case .swimming: return "Swimming"
        case .hiking: return "Hiking"
        case .yoga: return "Yoga"
        case .functionalStrengthTraining: return "Strength Training"
        case .traditionalStrengthTraining: return "Strength Training"
        case .highIntensityIntervalTraining: return "HIIT"
        case .elliptical: return "Elliptical"
        case .rowing: return "Rowing"
        default: return "Workout"
        }
    }
}

// MARK: - Workout Route Payloads

struct WorkoutRoutePayload: Codable, Sendable {
    let workoutHkUuid: String
    let points: [RoutePoint]

    enum CodingKeys: String, CodingKey {
        case workoutHkUuid = "workout_hk_uuid"
        case points
    }
}

struct RoutePoint: Codable, Sendable {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let horizontalAccuracy: Double?
    let verticalAccuracy: Double?
    let speed: Double?
    let course: Double?

    enum CodingKeys: String, CodingKey {
        case timestamp, latitude, longitude, altitude
        case horizontalAccuracy = "horizontal_accuracy"
        case verticalAccuracy = "vertical_accuracy"
        case speed, course
    }
}
