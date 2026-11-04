import Foundation
@preconcurrency import Speech

/// Compiles a food-vocabulary `SFCustomLanguageModelData` corpus on first use
/// and caches the compiled `.bin` in Application Support. The compiled model
/// biases the on-device recognizer toward food names, cooking methods, and
/// portion words — which Siri's general model handles poorly.
enum FoodLanguageModel {
    private static let clientIdentifier = "com.ladvien.selfsensored.foodmodel"
    private static let corpusVersion = "1"

    static func configuration() async -> SFSpeechLanguageModel.Configuration? {
        do {
            let compiled = try await compileIfNeeded()
            return SFSpeechLanguageModel.Configuration(languageModel: compiled)
        } catch {
            print("FoodLanguageModel compile failed: \(error)")
            return nil
        }
    }

    private static func compileIfNeeded() async throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let compiled = dir.appendingPathComponent("foodmodel-v\(corpusVersion).bin")
        if fm.fileExists(atPath: compiled.path) {
            return compiled
        }

        let source = dir.appendingPathComponent("foodmodel-v\(corpusVersion).source")
        let data = SFCustomLanguageModelData(
            locale: Locale(identifier: "en-US"),
            identifier: clientIdentifier,
            version: corpusVersion
        ) {
            for phrase in foodPhrases {
                SFCustomLanguageModelData.PhraseCount(phrase: phrase, count: 10)
            }
            for phrase in preparationPhrases {
                SFCustomLanguageModelData.PhraseCount(phrase: phrase, count: 6)
            }
            for phrase in portionPhrases {
                SFCustomLanguageModelData.PhraseCount(phrase: phrase, count: 8)
            }
        }
        try await data.export(to: source)
        try await SFSpeechLanguageModel.prepareCustomLanguageModel(
            for: source,
            clientIdentifier: clientIdentifier,
            configuration: SFSpeechLanguageModel.Configuration(languageModel: compiled)
        )
        return compiled
    }

    private static let foodPhrases: [String] = [
        "grilled chicken breast", "baked salmon", "ahi tuna", "ground beef",
        "pork tenderloin", "rotisserie chicken", "turkey breast", "lamb shank",
        "scrambled eggs", "greek yogurt", "cottage cheese", "cheddar cheese",
        "brown rice", "jasmine rice", "basmati rice", "quinoa bowl",
        "sweet potato", "whole wheat bread", "sourdough toast", "rolled oats",
        "steel-cut oats", "overnight oats", "corn tortilla", "flour tortilla",
        "avocado toast", "kale salad", "caesar salad", "cobb salad",
        "chicken caesar", "poke bowl", "burrito bowl", "chipotle bowl",
        "pad thai", "chicken tikka masala", "butter chicken", "palak paneer",
        "dal makhani", "chana masala", "biryani", "tandoori chicken",
        "chicken pho", "beef pho", "banh mi", "spring rolls", "summer rolls",
        "sushi roll", "salmon nigiri", "ramen", "udon noodles", "miso soup",
        "bulgogi", "bibimbap", "kimchi fried rice", "japchae",
        "shakshuka", "hummus", "falafel wrap", "gyro", "dolma", "tzatziki",
        "ceviche", "tacos al pastor", "carne asada", "fish tacos",
        "enchiladas", "tamale", "pozole", "chiles rellenos",
        "margherita pizza", "pepperoni pizza", "lasagna", "fettuccine alfredo",
        "spaghetti bolognese", "chicken parmesan", "eggplant parmesan",
        "risotto", "gnocchi", "carbonara",
        "açaí bowl", "matcha latte", "oat milk latte", "cold brew",
        "kombucha", "boba tea", "chai latte",
        "protein shake", "whey protein", "casein protein", "creatine",
        "almond butter", "peanut butter", "nutella", "granola",
        "blueberries", "raspberries", "strawberries", "blackberries",
        "pomegranate seeds", "dragon fruit", "mango", "papaya", "passion fruit",
        "edamame", "tempeh", "tofu", "seitan", "jackfruit",
    ]

    private static let preparationPhrases: [String] = [
        "grilled", "pan-seared", "roasted", "broiled", "baked", "air-fried",
        "deep-fried", "stir-fried", "sautéed", "poached", "steamed", "smoked",
        "braised", "blackened", "charred",
    ]

    private static let portionPhrases: [String] = [
        "six ounces", "four ounces", "eight ounces", "three ounces", "two ounces",
        "half a cup", "a quarter cup", "a cup of", "two cups of", "a bowl of",
        "a handful of", "a glass of", "a tablespoon", "a teaspoon",
        "one slice", "two slices", "a serving", "a medium", "a large",
    ]
}
