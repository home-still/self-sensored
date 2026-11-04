import HealthKit

/// Registry of all HealthKit types this app requests read access for.
enum HKTypes {
    // MARK: - Quantity Types (time-series numeric samples)

    static let quantityTypes: Set<HKQuantityType> = {
        let identifiers: [HKQuantityTypeIdentifier] = [
            // Body
            .bodyMass,
            .bodyMassIndex,
            .bodyFatPercentage,
            .height,
            .leanBodyMass,
            .waistCircumference,

            // Fitness - Steps & Counts
            .stepCount,
            .flightsClimbed,
            .pushCount,
            .swimmingStrokeCount,
            .nikeFuel,
            .numberOfTimesFallen,

            // Fitness - Distance
            .distanceWalkingRunning,
            .distanceCycling,
            .distanceSwimming,
            .distanceWheelchair,
            .distanceDownhillSnowSports,

            // Activity / Energy
            .basalEnergyBurned,
            .activeEnergyBurned,
            .appleExerciseTime,
            .appleMoveTime,
            .appleStandTime,

            // Vitals - Heart
            .heartRate,
            .restingHeartRate,
            .walkingHeartRateAverage,
            .heartRateVariabilitySDNN,
            .atrialFibrillationBurden,

            // Vitals - Respiratory
            .respiratoryRate,
            .oxygenSaturation,

            // Vitals - Blood Pressure
            .bloodPressureSystolic,
            .bloodPressureDiastolic,

            // Vitals - Temperature
            .bodyTemperature,
            .basalBodyTemperature,
            .appleSleepingWristTemperature,

            // Vitals - Other
            .peripheralPerfusionIndex,
            .vo2Max,
            .electrodermalActivity,

            // Lab / Blood
            .bloodGlucose,
            .insulinDelivery,
            .numberOfAlcoholicBeverages,

            // Lung Function
            .forcedExpiratoryVolume1,
            .forcedVitalCapacity,
            .peakExpiratoryFlowRate,
            .inhalerUsage,

            // Walking & Running Metrics
            .walkingSpeed,
            .walkingStepLength,
            .walkingDoubleSupportPercentage,
            .walkingAsymmetryPercentage,
            .stairAscentSpeed,
            .stairDescentSpeed,
            .sixMinuteWalkTestDistance,

            // Running Metrics
            .runningSpeed,
            .runningStrideLength,
            .runningPower,
            .runningGroundContactTime,
            .runningVerticalOscillation,

            // Cycling Metrics
            .cyclingSpeed,
            .cyclingPower,
            .cyclingCadence,
            .cyclingFunctionalThresholdPower,

            // Nutrition - Macros
            .dietaryEnergyConsumed,
            .dietaryProtein,
            .dietaryCarbohydrates,
            .dietaryFatTotal,
            .dietaryFatSaturated,
            .dietaryFatMonounsaturated,
            .dietaryFatPolyunsaturated,
            .dietaryCholesterol,
            .dietaryFiber,
            .dietarySugar,

            // Nutrition - Minerals
            .dietaryCalcium,
            .dietaryIron,
            .dietaryPotassium,
            .dietarySodium,
            .dietaryZinc,
            .dietaryMagnesium,
            .dietaryManganese,
            .dietaryPhosphorus,
            .dietaryCopper,
            .dietaryChromium,
            .dietaryIodine,
            .dietaryMolybdenum,
            .dietarySelenium,

            // Nutrition - Vitamins
            .dietaryVitaminA,
            .dietaryVitaminB6,
            .dietaryVitaminB12,
            .dietaryVitaminC,
            .dietaryVitaminD,
            .dietaryVitaminE,
            .dietaryVitaminK,
            .dietaryBiotin,
            .dietaryFolate,
            .dietaryNiacin,
            .dietaryPantothenicAcid,
            .dietaryRiboflavin,
            .dietaryThiamin,

            // Nutrition - Other
            .dietaryCaffeine,
            .dietaryWater,

            // Audio
            .environmentalAudioExposure,
            .headphoneAudioExposure,
            .environmentalSoundReduction,

            // UV
            .uvExposure,
        ]
        return Set(identifiers.map { HKQuantityType($0) })
    }()

    // MARK: - Category Types (enum-valued samples)

    static let categoryTypes: Set<HKCategoryType> = {
        let identifiers: [HKCategoryTypeIdentifier] = [
            // Sleep
            .sleepAnalysis,

            // Activity
            .appleStandHour,

            // Mindfulness
            .mindfulSession,

            // Heart Events
            .highHeartRateEvent,
            .lowHeartRateEvent,
            .irregularHeartRhythmEvent,

            // Reproductive Health
            .menstrualFlow,
            .intermenstrualBleeding,
            .ovulationTestResult,
            .cervicalMucusQuality,
            .sexualActivity,
            .contraceptive,
            .pregnancy,
            .lactation,

            // Symptoms
            .appetiteChanges,
            .generalizedBodyAche,
            .bloating,
            .breastPain,
            .chestTightnessOrPain,
            .constipation,
            .coughing,
            .diarrhea,
            .dizziness,
            .drySkin,
            .fainting,
            .fatigue,
            .fever,
            .headache,
            .heartburn,
            .hotFlashes,
            .lossOfSmell,
            .lossOfTaste,
            .lowerBackPain,
            .memoryLapse,
            .moodChanges,
            .nausea,
            .nightSweats,
            .pelvicPain,
            .rapidPoundingOrFlutteringHeartbeat,
            .runnyNose,
            .shortnessOfBreath,
            .sinusCongestion,
            .skippedHeartbeat,
            .sleepChanges,
            .soreThroat,
            .vaginalDryness,
            .vomiting,
            .wheezing,
            .abdominalCramps,
            .acne,
            .bladderIncontinence,
            .chills,
            .hairLoss,

            // Other
            .handwashingEvent,
            .toothbrushingEvent,
            .lowCardioFitnessEvent,
        ]
        return Set(identifiers.map { HKCategoryType($0) })
    }()

    // MARK: - All readable types

    static var allReadTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        types.formUnion(quantityTypes)
        types.formUnion(categoryTypes)
        types.insert(HKObjectType.workoutType())
        types.insert(HKSeriesType.workoutRoute())
        types.insert(HKObjectType.activitySummaryType())
        return types
    }

    /// All sample types suitable for anchored queries and background delivery.
    static var allSampleTypes: [HKSampleType] {
        var types = [HKSampleType]()
        types.append(contentsOf: quantityTypes.map { $0 as HKSampleType })
        types.append(contentsOf: categoryTypes.map { $0 as HKSampleType })
        types.append(HKSampleType.workoutType())
        return types
    }

    // MARK: - Writable types (voice meal logging)

    /// Dietary quantity identifiers the app writes to HealthKit when the user
    /// logs a meal. Mirrors the server-side `nutrient_healthkit_map` rows.
    static let dietaryWriteIdentifiers: [HKQuantityTypeIdentifier] = [
        .dietaryEnergyConsumed,
        .dietaryProtein,
        .dietaryFatTotal,
        .dietaryFatSaturated,
        .dietaryFatMonounsaturated,
        .dietaryFatPolyunsaturated,
        .dietaryCholesterol,
        .dietaryCarbohydrates,
        .dietaryFiber,
        .dietarySugar,
        .dietaryWater,
        .dietaryCaffeine,
        .dietarySodium,
        .dietaryPotassium,
        .dietaryCalcium,
        .dietaryIron,
        .dietaryMagnesium,
        .dietaryPhosphorus,
        .dietaryZinc,
        .dietaryCopper,
        .dietaryManganese,
        .dietarySelenium,
        .dietaryChloride,
        .dietaryChromium,
        .dietaryIodine,
        .dietaryMolybdenum,
        .dietaryVitaminA,
        .dietaryThiamin,
        .dietaryRiboflavin,
        .dietaryNiacin,
        .dietaryPantothenicAcid,
        .dietaryVitaminB6,
        .dietaryBiotin,
        .dietaryFolate,
        .dietaryVitaminB12,
        .dietaryVitaminC,
        .dietaryVitaminD,
        .dietaryVitaminE,
        .dietaryVitaminK,
    ]

    static var allWriteTypes: Set<HKSampleType> {
        // Only the underlying quantity types are authorizable. The food
        // correlation that wraps them inherits authorization from its
        // constituents — including HKCorrelationType.food in this set throws
        // `Authorization to share the following types is disallowed` at app
        // launch on iOS 17+.
        var types = Set<HKSampleType>()
        for id in dietaryWriteIdentifiers {
            types.insert(HKQuantityType(id))
        }
        return types
    }
}
