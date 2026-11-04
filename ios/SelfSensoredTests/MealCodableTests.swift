import XCTest
@testable import SelfSensored

/// Round-trip tests for the JSON shapes returned by the API. These guard the
/// iOS client against silent server-side renames.
final class MealCodableTests: XCTestCase {
    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func testDecodesMealNutritionResponse() throws {
        let body = #"""
        {
            "sync_identifier": "11111111-1111-1111-1111-111111111111",
            "meal_type": "lunch",
            "items": [
                {
                    "parsed": {
                        "food_name": "grilled chicken breast",
                        "quantity": 6.0,
                        "unit": "oz",
                        "preparation_method": "grilled",
                        "confidence": "high",
                        "database_search_terms": ["grilled chicken breast", "chicken"]
                    },
                    "matched_food": {
                        "fdc_id": 171477,
                        "name": "Chicken, breast, cooked, grilled",
                        "data_type": "sr_legacy_food"
                    },
                    "grams": 170.097,
                    "nutrients": []
                }
            ],
            "totals": [
                {
                    "hk_identifier": "HKQuantityTypeIdentifierDietaryProtein",
                    "unit": "G",
                    "amount": 52.7,
                    "sparse": false
                }
            ]
        }
        """#.data(using: .utf8)!

        let response = try decoder.decode(MealNutritionResponse.self, from: body)
        XCTAssertEqual(response.mealType, "lunch")
        XCTAssertEqual(response.items.count, 1)
        XCTAssertEqual(response.items[0].parsed.foodName, "grilled chicken breast")
        XCTAssertEqual(response.items[0].matchedFood?.fdcId, 171477)
        XCTAssertEqual(response.totals.count, 1)
        XCTAssertEqual(response.totals[0].hkIdentifier, "HKQuantityTypeIdentifierDietaryProtein")
    }

    func testDecodesMealHistoryResponseWithCursor() throws {
        let body = #"""
        {
            "items": [
                {
                    "id": "22222222-2222-2222-2222-222222222222",
                    "sync_identifier": "33333333-3333-3333-3333-333333333333",
                    "raw_text": "yogurt",
                    "meal_type": "snack",
                    "created_at": "2026-04-13T12:00:00Z",
                    "totals": {
                        "calories_kcal": 150.0,
                        "protein_g": 12.0,
                        "carbs_g": 18.0,
                        "fat_g": 3.0
                    }
                }
            ],
            "next_before": "2026-04-13T12:00:00Z"
        }
        """#.data(using: .utf8)!

        let response = try decoder.decode(MealHistoryResponse.self, from: body)
        XCTAssertEqual(response.items.count, 1)
        XCTAssertEqual(response.items[0].rawText, "yogurt")
        XCTAssertEqual(response.items[0].totals.caloriesKcal, 150.0)
        XCTAssertNotNil(response.nextBefore)
    }

    func testDecodesEmptyHistoryWithoutCursor() throws {
        let body = #"""
        { "items": [], "next_before": null }
        """#.data(using: .utf8)!
        let response = try decoder.decode(MealHistoryResponse.self, from: body)
        XCTAssertTrue(response.items.isEmpty)
        XCTAssertNil(response.nextBefore)
    }
}
