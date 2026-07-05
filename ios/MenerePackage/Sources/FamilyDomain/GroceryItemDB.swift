import Foundation

/// Local database of common grocery items mapped to aisle categories.
///
/// Ported from Fambo's `GroceryItemDB` (P30). Provides instant, free (no-network)
/// categorization + autocomplete for common items. Kept as a pure-Foundation namespace so
/// `FamilyDomain` stays dependency-free; call the static methods directly.
public enum GroceryItemDB {
    /// Best-effort aisle for a free-typed item name. Exact match first, then a loose
    /// contains-match, else `nil` (renders under "Other" / uncategorized).
    public static func categorize(_ itemName: String) -> GroceryCategory? {
        let normalized = itemName.lowercased().trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return nil }
        if let category = itemDatabase[normalized] {
            return category
        }
        for (key, category) in itemDatabase where normalized.contains(key) || key.contains(normalized) {
            return category
        }
        return nil
    }

    /// Up to 8 capitalized autocomplete suggestions whose name starts with `prefix`
    /// (min 2 chars). Used while typing a new grocery item.
    public static func suggestions(prefix: String) -> [String] {
        let normalized = prefix.lowercased().trimmingCharacters(in: .whitespaces)
        guard normalized.count >= 2 else { return [] }
        return itemDatabase.keys
            .filter { $0.hasPrefix(normalized) }
            .sorted()
            .prefix(8)
            .map { $0.capitalized }
    }
}

// MARK: - Item Database

private let itemDatabase: [String: GroceryCategory] = {
    var db = [String: GroceryCategory]()

    let produce: [String] = [
        "apple", "apples", "avocado", "avocados", "banana", "bananas", "basil",
        "bell pepper", "bell peppers", "blueberries", "broccoli", "cabbage",
        "carrots", "carrot", "cauliflower", "celery", "cherries", "cilantro",
        "corn", "cucumber", "cucumbers", "eggplant", "garlic", "ginger",
        "grapes", "green beans", "green onion", "green onions", "herbs",
        "jalapeño", "kale", "leek", "lemon", "lemons", "lettuce", "lime",
        "limes", "mango", "mangoes", "melon", "mint", "mushrooms", "mushroom",
        "onion", "onions", "orange", "oranges", "parsley", "peach", "peaches",
        "pear", "pears", "peas", "pineapple", "plum", "plums", "potato",
        "potatoes", "radish", "raspberries", "rosemary", "salad", "scallions",
        "shallot", "shallots", "spinach", "squash", "strawberries",
        "sweet potato", "sweet potatoes", "thyme", "tomato", "tomatoes",
        "watermelon", "zucchini",
    ]

    let dairy: [String] = [
        "butter", "cheddar", "cheese", "cottage cheese", "cream", "cream cheese",
        "egg", "eggs", "feta", "goat cheese", "greek yogurt", "half and half",
        "heavy cream", "milk", "mozzarella", "parmesan", "ricotta",
        "shredded cheese", "sour cream", "whipping cream", "yogurt",
    ]

    let meat: [String] = [
        "bacon", "beef", "chicken", "chicken breast", "chicken thighs",
        "ground beef", "ground turkey", "ham", "hot dogs", "lamb",
        "pork", "pork chops", "pork loin", "sausage", "steak",
        "turkey", "veal",
    ]

    let seafood: [String] = [
        "catfish", "clams", "cod", "crab", "fish", "halibut", "lobster",
        "mussels", "oysters", "salmon", "scallops", "shrimp", "tilapia",
        "tuna",
    ]

    let bakery: [String] = [
        "bagel", "bagels", "baguette", "bread", "buns", "cake",
        "ciabatta", "cornbread", "croissant", "croissants", "dinner rolls",
        "english muffins", "flatbread", "hamburger buns", "hot dog buns",
        "muffins", "naan", "pita", "rolls", "sourdough", "tortillas",
        "wheat bread", "white bread", "whole wheat bread", "wraps",
    ]

    let frozen: [String] = [
        "frozen berries", "frozen broccoli", "frozen corn", "frozen dinner",
        "frozen fruit", "frozen peas", "frozen pizza", "frozen vegetables",
        "frozen waffles", "ice cream", "ice pops", "popsicles",
    ]

    let pantry: [String] = [
        "all-purpose flour", "almond butter", "almonds", "baking powder",
        "baking soda", "black beans", "bouillon", "breadcrumbs", "brown rice",
        "brown sugar", "canola oil", "cashews", "cereal", "chia seeds",
        "chicken broth", "chickpeas", "chili powder", "cocoa powder",
        "coconut milk", "coconut oil", "cooking spray", "cornstarch",
        "couscous", "cumin", "dried oregano", "flour", "granola",
        "honey", "italian seasoning", "jam", "jelly", "ketchup",
        "lentils", "maple syrup", "marinara sauce", "mayonnaise",
        "mustard", "nutritional yeast", "oatmeal", "oats",
        "olive oil", "oregano", "orzo", "pancake mix", "panko",
        "paprika", "pasta", "pasta sauce", "peanut butter", "peanuts",
        "pecans", "pepper", "quinoa", "ranch dressing", "red pepper flakes",
        "rice", "salad dressing", "salt", "sesame oil", "soy sauce",
        "spaghetti", "sriracha", "stock", "sugar", "tahini",
        "tomato paste", "tomato sauce", "tuna can", "vanilla extract",
        "vegetable broth", "vegetable oil", "vinegar", "walnuts",
        "white rice", "worcestershire sauce",
    ]

    let beverages: [String] = [
        "apple juice", "beer", "bottled water", "club soda", "coconut water",
        "coffee", "diet coke", "energy drink", "ginger ale", "grape juice",
        "green tea", "juice", "kombucha", "lemonade", "oat milk",
        "almond milk", "orange juice", "seltzer", "soda", "sparkling water",
        "tea", "tonic water", "water", "wine",
    ]

    let snacks: [String] = [
        "applesauce", "cheese crackers", "chips", "chocolate", "cookies",
        "crackers", "dark chocolate", "dried fruit", "fruit snacks",
        "goldfish", "graham crackers", "granola bars", "hummus",
        "jerky", "mixed nuts", "nuts", "pita chips", "popcorn",
        "pretzels", "protein bar", "raisins", "rice cakes", "salsa",
        "string cheese", "tortilla chips", "trail mix",
    ]

    let deli: [String] = [
        "deli meat", "deli turkey", "ham slices", "hummus dip",
        "olive bar", "pepperoni", "prosciutto", "rotisserie chicken",
        "salami", "sliced cheese", "sliced turkey", "smoked salmon",
        "turkey breast",
    ]

    let household: [String] = [
        "aluminum foil", "batteries", "bleach", "broom", "cleaning spray",
        "clorox wipes", "dish soap", "dryer sheets", "garbage bags",
        "hand soap", "laundry detergent", "light bulbs", "napkins",
        "paper plates", "paper towels", "plastic bags", "plastic wrap",
        "sponges", "toilet paper", "trash bags", "windex", "zip bags",
        "ziploc bags",
    ]

    let health: [String] = [
        "bandaids", "body wash", "conditioner", "cotton balls",
        "deodorant", "dental floss", "face wash", "first aid",
        "hand sanitizer", "ibuprofen", "lotion", "mouthwash",
        "razors", "shampoo", "soap", "sunscreen", "tissues",
        "toothbrush", "toothpaste", "vitamins",
    ]

    let baby: [String] = [
        "baby food", "baby formula", "baby lotion", "baby shampoo",
        "baby wipes", "diapers", "diaper cream", "formula",
        "infant tylenol", "nursing pads", "pacifier", "sippy cup",
    ]

    let pets: [String] = [
        "cat food", "cat litter", "cat treats", "dog food", "dog treats",
        "flea treatment", "pet food", "pet shampoo", "pet treats",
    ]

    for item in produce { db[item] = .produce }
    for item in dairy { db[item] = .dairy }
    for item in meat { db[item] = .meat }
    for item in seafood { db[item] = .seafood }
    for item in bakery { db[item] = .bakery }
    for item in frozen { db[item] = .frozen }
    for item in pantry { db[item] = .pantry }
    for item in beverages { db[item] = .beverages }
    for item in snacks { db[item] = .snacks }
    for item in deli { db[item] = .deli }
    for item in household { db[item] = .household }
    for item in health { db[item] = .health }
    for item in baby { db[item] = .baby }
    for item in pets { db[item] = .pets }

    return db
}()
