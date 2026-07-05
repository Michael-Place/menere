import Foundation

/// The seeded home-maintenance library — 91 tasks across 9 categories, ported verbatim from
/// Fambo (P29). Titles/descriptions are plain English (Fambo's localization wrappers dropped).
/// Each template carries a default cadence, an optional season, difficulty, `requires*` gates
/// (yard/pool/basement/garage/septic/HVAC), and an estimate.
public enum MaintenanceKnowledgeBase {

    /// Every seeded template, all categories concatenated.
    public static let allTasks: [MaintenanceTemplate] =
        hvacTasks + plumbingTasks + electricalTasks + exteriorTasks + interiorTasks + appliancesTasks + safetyTasks + yardTasks + poolTasks

    /// Templates applicable to a given home — drops tasks whose `requires*` gate the profile
    /// doesn't satisfy (no pool → no pool tasks, no HVAC → no filter changes, …).
    public static func filterForHome(_ profile: HomeProfile) -> [MaintenanceTemplate] {
        allTasks.filter { task in
            if task.requiresYard && !profile.hasYard { return false }
            if task.requiresPool && !profile.hasPool { return false }
            if task.requiresBasement && !profile.hasBasement { return false }
            if task.requiresGarage && !profile.hasGarage { return false }
            if task.requiresSepticSystem && !profile.hasSepticSystem { return false }
            if task.requiresHVAC && (profile.hvacType == nil || profile.hvacType == HVACType.none) { return false }
            return true
        }
    }

    /// The applicable templates whose season is nil (any time) or matches `season`.
    public static func suggestedForSeason(_ season: Season, profile: HomeProfile) -> [MaintenanceTemplate] {
        filterForHome(profile).filter { $0.season == nil || $0.season == season }
    }

    // MARK: - HVAC

    static let hvacTasks: [MaintenanceTemplate] = [
        MaintenanceTemplate(
            id: "hvac-change-air-filter",
            title: "Change air filter",
            description: "Replace the HVAC air filter to maintain air quality and system efficiency.",
            category: .hvac,
            frequency: .monthly,
            difficulty: .easy,
            requiresHVAC: true,
            estimatedMinutes: 10
        ),
        MaintenanceTemplate(
            id: "hvac-schedule-ac-tuneup",
            title: "Schedule AC tune-up",
            description: "Have a professional inspect and service the air conditioning system before summer.",
            category: .hvac,
            frequency: .annual,
            difficulty: .easy,
            season: .spring,
            requiresHVAC: true,
            estimatedMinutes: 15
        ),
        MaintenanceTemplate(
            id: "hvac-clean-vents",
            title: "Clean vents and registers",
            description: "Vacuum and wipe down all air vents and registers throughout the home.",
            category: .hvac,
            frequency: .quarterly,
            difficulty: .easy,
            requiresHVAC: true,
            estimatedMinutes: 30
        ),
        MaintenanceTemplate(
            id: "hvac-inspect-ductwork",
            title: "Inspect ductwork",
            description: "Check visible ductwork for leaks, gaps, or damage that reduces efficiency.",
            category: .hvac,
            frequency: .annual,
            difficulty: .medium,
            requiresHVAC: true,
            estimatedMinutes: 45
        ),
        MaintenanceTemplate(
            id: "hvac-clean-condenser",
            title: "Clean outdoor condenser unit",
            description: "Remove debris and clean the outdoor AC condenser coils and fins.",
            category: .hvac,
            frequency: .annual,
            difficulty: .medium,
            season: .spring,
            requiresHVAC: true,
            estimatedMinutes: 45
        ),
        MaintenanceTemplate(
            id: "hvac-schedule-heating-tuneup",
            title: "Schedule heating tune-up",
            description: "Have a professional inspect and service the heating system before winter.",
            category: .hvac,
            frequency: .annual,
            difficulty: .easy,
            season: .fall,
            requiresHVAC: true,
            estimatedMinutes: 15
        ),
        MaintenanceTemplate(
            id: "hvac-check-thermostat",
            title: "Check thermostat calibration",
            description: "Verify the thermostat reads accurately and programs are set correctly.",
            category: .hvac,
            frequency: .semiannual,
            difficulty: .easy,
            requiresHVAC: true,
            estimatedMinutes: 10
        ),
        MaintenanceTemplate(
            id: "hvac-clean-humidifier",
            title: "Clean humidifier",
            description: "Clean or replace the humidifier pad and check for mineral buildup.",
            category: .hvac,
            frequency: .annual,
            difficulty: .medium,
            season: .fall,
            requiresHVAC: true,
            estimatedMinutes: 30
        ),
        MaintenanceTemplate(
            id: "hvac-bleed-radiators",
            title: "Bleed radiators",
            description: "Release trapped air from radiators to ensure even heating.",
            category: .hvac,
            frequency: .annual,
            difficulty: .easy,
            season: .fall,
            requiresHVAC: true,
            estimatedMinutes: 30
        ),
    ]

    // MARK: - Plumbing

    static let plumbingTasks: [MaintenanceTemplate] = [
        MaintenanceTemplate(
            id: "plumbing-check-leaks",
            title: "Check for leaks",
            description: "Inspect under sinks, around toilets, and near appliances for signs of water leaks.",
            category: .plumbing,
            frequency: .monthly,
            difficulty: .easy,
            estimatedMinutes: 15
        ),
        MaintenanceTemplate(
            id: "plumbing-flush-water-heater",
            title: "Flush water heater",
            description: "Drain sediment from the water heater tank to maintain efficiency and extend its life.",
            category: .plumbing,
            frequency: .annual,
            difficulty: .medium,
            estimatedMinutes: 60
        ),
        MaintenanceTemplate(
            id: "plumbing-clean-drains",
            title: "Clean drains",
            description: "Clear slow drains using a drain snake or enzyme cleaner to prevent clogs.",
            category: .plumbing,
            frequency: .quarterly,
            difficulty: .easy,
            estimatedMinutes: 20
        ),
        MaintenanceTemplate(
            id: "plumbing-test-sump-pump",
            title: "Test sump pump",
            description: "Pour water into the sump pit and verify the pump activates and drains properly.",
            category: .plumbing,
            frequency: .quarterly,
            difficulty: .easy,
            requiresBasement: true,
            estimatedMinutes: 10
        ),
        MaintenanceTemplate(
            id: "plumbing-inspect-water-heater-anode",
            title: "Inspect water heater anode rod",
            description: "Check the sacrificial anode rod and replace if significantly corroded.",
            category: .plumbing,
            frequency: .annual,
            difficulty: .medium,
            estimatedMinutes: 30
        ),
        MaintenanceTemplate(
            id: "plumbing-check-water-pressure",
            title: "Check water pressure",
            description: "Test water pressure with a gauge. Ideal range is 40-60 PSI.",
            category: .plumbing,
            frequency: .semiannual,
            difficulty: .easy,
            estimatedMinutes: 10
        ),
        MaintenanceTemplate(
            id: "plumbing-clean-faucet-aerators",
            title: "Clean faucet aerators",
            description: "Remove and clean mineral deposits from faucet aerators for better water flow.",
            category: .plumbing,
            frequency: .quarterly,
            difficulty: .easy,
            estimatedMinutes: 15
        ),
        MaintenanceTemplate(
            id: "plumbing-inspect-hose-bibs",
            title: "Inspect outdoor hose bibs",
            description: "Check outdoor faucets for leaks and ensure they shut off completely.",
            category: .plumbing,
            frequency: .semiannual,
            difficulty: .easy,
            estimatedMinutes: 10
        ),
        MaintenanceTemplate(
            id: "plumbing-winterize-pipes",
            title: "Winterize outdoor pipes",
            description: "Disconnect hoses, shut off exterior water supply, and insulate exposed pipes.",
            category: .plumbing,
            frequency: .annual,
            difficulty: .medium,
            season: .fall,
            estimatedMinutes: 45
        ),
        MaintenanceTemplate(
            id: "plumbing-pump-septic-tank",
            title: "Pump septic tank",
            description: "Schedule professional septic tank pumping to prevent backup and system failure.",
            category: .plumbing,
            frequency: .annual,
            difficulty: .easy,
            requiresSepticSystem: true,
            estimatedMinutes: 15
        ),
        MaintenanceTemplate(
            id: "plumbing-inspect-toilet-components",
            title: "Inspect toilet components",
            description: "Check flappers, fill valves, and seals for wear. Replace if running or leaking.",
            category: .plumbing,
            frequency: .semiannual,
            difficulty: .easy,
            estimatedMinutes: 15
        ),
    ]

    // MARK: - Electrical

    static let electricalTasks: [MaintenanceTemplate] = [
        MaintenanceTemplate(
            id: "electrical-test-gfci",
            title: "Test GFCI outlets",
            description: "Press the test and reset buttons on all GFCI outlets to verify they trip correctly.",
            category: .electrical,
            frequency: .monthly,
            difficulty: .easy,
            estimatedMinutes: 10
        ),
        MaintenanceTemplate(
            id: "electrical-test-smoke-detectors",
            title: "Test smoke detectors",
            description: "Press the test button on each smoke detector to verify it sounds the alarm.",
            category: .electrical,
            frequency: .monthly,
            difficulty: .easy,
            estimatedMinutes: 10
        ),
        MaintenanceTemplate(
            id: "electrical-replace-smoke-batteries",
            title: "Replace smoke detector batteries",
            description: "Replace batteries in all smoke detectors, even if they haven't chirped yet.",
            category: .electrical,
            frequency: .semiannual,
            difficulty: .easy,
            estimatedMinutes: 20
        ),
        MaintenanceTemplate(
            id: "electrical-check-breaker-panel",
            title: "Check breaker panel",
            description: "Inspect the breaker panel for signs of corrosion, heat damage, or tripped breakers.",
            category: .electrical,
            frequency: .annual,
            difficulty: .medium,
            estimatedMinutes: 15
        ),
        MaintenanceTemplate(
            id: "electrical-inspect-cords-plugs",
            title: "Inspect cords and plugs",
            description: "Check electrical cords and plugs for fraying, cracking, or heat damage.",
            category: .electrical,
            frequency: .semiannual,
            difficulty: .easy,
            estimatedMinutes: 15
        ),
        MaintenanceTemplate(
            id: "electrical-test-arc-fault-breakers",
            title: "Test arc-fault breakers",
            description: "Press the test button on AFCI breakers in the panel to verify they trip properly.",
            category: .electrical,
            frequency: .monthly,
            difficulty: .easy,
            estimatedMinutes: 5
        ),
        MaintenanceTemplate(
            id: "electrical-clean-light-fixtures",
            title: "Clean light fixtures",
            description: "Remove dust and debris from light fixtures and replace any burned-out bulbs.",
            category: .electrical,
            frequency: .quarterly,
            difficulty: .easy,
            estimatedMinutes: 30
        ),
        MaintenanceTemplate(
            id: "electrical-check-outdoor-lighting",
            title: "Check outdoor lighting",
            description: "Test all exterior lights, replace bulbs, and check timers or sensors.",
            category: .electrical,
            frequency: .quarterly,
            difficulty: .easy,
            estimatedMinutes: 20
        ),
    ]

    // MARK: - Exterior

    static let exteriorTasks: [MaintenanceTemplate] = [
        MaintenanceTemplate(
            id: "exterior-clean-gutters",
            title: "Clean gutters",
            description: "Remove leaves, debris, and buildup from gutters and downspouts.",
            category: .exterior,
            frequency: .semiannual,
            difficulty: .medium,
            season: .fall,
            estimatedMinutes: 90
        ),
        MaintenanceTemplate(
            id: "exterior-clean-gutters-spring",
            title: "Clean gutters (spring)",
            description: "Clear winter debris from gutters and check for damage from ice or snow.",
            category: .exterior,
            frequency: .semiannual,
            difficulty: .medium,
            season: .spring,
            estimatedMinutes: 90
        ),
        MaintenanceTemplate(
            id: "exterior-inspect-roof",
            title: "Inspect roof",
            description: "Look for missing, damaged, or curling shingles and check flashing around vents.",
            category: .exterior,
            frequency: .annual,
            difficulty: .medium,
            season: .spring,
            estimatedMinutes: 30
        ),
        MaintenanceTemplate(
            id: "exterior-power-wash-siding",
            title: "Power wash siding",
            description: "Clean exterior siding with a pressure washer to remove dirt, mold, and mildew.",
            category: .exterior,
            frequency: .annual,
            difficulty: .medium,
            season: .spring,
            estimatedMinutes: 120
        ),
        MaintenanceTemplate(
            id: "exterior-check-caulking",
            title: "Check caulking around windows and doors",
            description: "Inspect and repair caulk and weatherstripping around windows and exterior doors.",
            category: .exterior,
            frequency: .annual,
            difficulty: .medium,
            season: .fall,
            estimatedMinutes: 60
        ),
        MaintenanceTemplate(
            id: "exterior-inspect-foundation",
            title: "Inspect foundation",
            description: "Walk the perimeter and check for cracks, settling, or water damage in the foundation.",
            category: .exterior,
            frequency: .annual,
            difficulty: .easy,
            season: .spring,
            estimatedMinutes: 20
        ),
        MaintenanceTemplate(
            id: "exterior-inspect-driveway",
            title: "Inspect driveway and walkways",
            description: "Check for cracks, heaving, or settling in concrete or asphalt surfaces.",
            category: .exterior,
            frequency: .annual,
            difficulty: .easy,
            season: .spring,
            estimatedMinutes: 15
        ),
        MaintenanceTemplate(
            id: "exterior-check-deck-patio",
            title: "Inspect deck or patio",
            description: "Check for loose boards, popped nails, rot, or unstable railings.",
            category: .exterior,
            frequency: .annual,
            difficulty: .medium,
            season: .spring,
            estimatedMinutes: 30
        ),
        MaintenanceTemplate(
            id: "exterior-seal-deck",
            title: "Seal or stain deck",
            description: "Apply sealant or stain to protect the deck from moisture and UV damage.",
            category: .exterior,
            frequency: .annual,
            difficulty: .hard,
            season: .spring,
            estimatedMinutes: 240
        ),
        MaintenanceTemplate(
            id: "exterior-inspect-siding",
            title: "Inspect siding",
            description: "Check for cracks, warping, rot, or pest damage on exterior siding.",
            category: .exterior,
            frequency: .annual,
            difficulty: .easy,
            season: .spring,
            estimatedMinutes: 20
        ),
        MaintenanceTemplate(
            id: "exterior-clean-garage-door",
            title: "Clean and lubricate garage door",
            description: "Clean the garage door tracks and lubricate moving parts, springs, and hinges.",
            category: .exterior,
            frequency: .semiannual,
            difficulty: .easy,
            requiresGarage: true,
            estimatedMinutes: 20
        ),
        MaintenanceTemplate(
            id: "exterior-test-garage-door-safety",
            title: "Test garage door safety reverse",
            description: "Place an object under the door and test that it reverses when contacting it.",
            category: .exterior,
            frequency: .monthly,
            difficulty: .easy,
            requiresGarage: true,
            estimatedMinutes: 5
        ),
    ]

    // MARK: - Interior

    static let interiorTasks: [MaintenanceTemplate] = [
        MaintenanceTemplate(
            id: "interior-deep-clean-kitchen",
            title: "Deep clean kitchen",
            description: "Thoroughly clean counters, cabinets, backsplash, and floor. Degrease range hood.",
            category: .interior,
            frequency: .monthly,
            difficulty: .medium,
            estimatedMinutes: 90
        ),
        MaintenanceTemplate(
            id: "interior-clean-behind-appliances",
            title: "Clean behind appliances",
            description: "Pull out refrigerator, stove, and washer/dryer to clean dust and debris behind them.",
            category: .interior,
            frequency: .quarterly,
            difficulty: .medium,
            estimatedMinutes: 45
        ),
        MaintenanceTemplate(
            id: "interior-wash-windows",
            title: "Wash windows",
            description: "Clean interior and exterior window surfaces, screens, and sills.",
            category: .interior,
            frequency: .quarterly,
            difficulty: .medium,
            estimatedMinutes: 60
        ),
        MaintenanceTemplate(
            id: "interior-check-grout-caulk",
            title: "Check grout and caulk",
            description: "Inspect grout and caulk in bathrooms and kitchen. Repair or replace as needed.",
            category: .interior,
            frequency: .semiannual,
            difficulty: .medium,
            estimatedMinutes: 45
        ),
        MaintenanceTemplate(
            id: "interior-deep-clean-bathrooms",
            title: "Deep clean bathrooms",
            description: "Scrub tile, grout, fixtures, and drains. Clean exhaust fan cover.",
            category: .interior,
            frequency: .monthly,
            difficulty: .medium,
            estimatedMinutes: 60
        ),
        MaintenanceTemplate(
            id: "interior-clean-range-hood-filter",
            title: "Clean range hood filter",
            description: "Remove and degrease the range hood filter. Soak in hot soapy water.",
            category: .interior,
            frequency: .quarterly,
            difficulty: .easy,
            estimatedMinutes: 20
        ),
        MaintenanceTemplate(
            id: "interior-vacuum-upholstery",
            title: "Vacuum upholstery and mattresses",
            description: "Vacuum all upholstered furniture and mattresses to remove dust and allergens.",
            category: .interior,
            frequency: .quarterly,
            difficulty: .easy,
            estimatedMinutes: 45
        ),
        MaintenanceTemplate(
            id: "interior-clean-ceiling-fans",
            title: "Clean ceiling fans",
            description: "Dust and wipe down ceiling fan blades and housings.",
            category: .interior,
            frequency: .quarterly,
            difficulty: .easy,
            estimatedMinutes: 20
        ),
        MaintenanceTemplate(
            id: "interior-check-basement",
            title: "Inspect basement for moisture",
            description: "Check basement walls, floors, and windows for signs of water intrusion or dampness.",
            category: .interior,
            frequency: .quarterly,
            difficulty: .easy,
            requiresBasement: true,
            estimatedMinutes: 15
        ),
        MaintenanceTemplate(
            id: "interior-clean-dryer-vent-interior",
            title: "Clean interior dryer vent connection",
            description: "Disconnect and clean the dryer vent hose behind the dryer.",
            category: .interior,
            frequency: .semiannual,
            difficulty: .medium,
            estimatedMinutes: 30
        ),
    ]

    // MARK: - Appliances

    static let appliancesTasks: [MaintenanceTemplate] = [
        MaintenanceTemplate(
            id: "appliances-clean-dishwasher",
            title: "Clean dishwasher",
            description: "Run an empty cycle with vinegar or dishwasher cleaner. Clean the filter and door seal.",
            category: .appliances,
            frequency: .monthly,
            difficulty: .easy,
            estimatedMinutes: 15
        ),
        MaintenanceTemplate(
            id: "appliances-clean-oven",
            title: "Clean oven",
            description: "Run self-clean cycle or manually clean oven interior, racks, and glass door.",
            category: .appliances,
            frequency: .quarterly,
            difficulty: .medium,
            estimatedMinutes: 30
        ),
        MaintenanceTemplate(
            id: "appliances-clean-dryer-vent",
            title: "Clean dryer vent",
            description: "Clean the full dryer vent line from the dryer to the exterior outlet to prevent fire.",
            category: .appliances,
            frequency: .semiannual,
            difficulty: .medium,
            estimatedMinutes: 45
        ),
        MaintenanceTemplate(
            id: "appliances-inspect-washer-hoses",
            title: "Inspect washing machine hoses",
            description: "Check hot and cold water supply hoses for bulges, cracks, or leaks. Replace if worn.",
            category: .appliances,
            frequency: .semiannual,
            difficulty: .easy,
            estimatedMinutes: 10
        ),
        MaintenanceTemplate(
            id: "appliances-clean-refrigerator-coils",
            title: "Clean refrigerator coils",
            description: "Vacuum the condenser coils under or behind the refrigerator to maintain efficiency.",
            category: .appliances,
            frequency: .annual,
            difficulty: .medium,
            estimatedMinutes: 30
        ),
        MaintenanceTemplate(
            id: "appliances-clean-garbage-disposal",
            title: "Clean garbage disposal",
            description: "Freshen the disposal with ice cubes and citrus peels. Check for leaks underneath.",
            category: .appliances,
            frequency: .monthly,
            difficulty: .easy,
            estimatedMinutes: 10
        ),
        MaintenanceTemplate(
            id: "appliances-clean-washer",
            title: "Clean washing machine",
            description: "Run a cleaning cycle with bleach or washer cleaner. Wipe the door gasket.",
            category: .appliances,
            frequency: .monthly,
            difficulty: .easy,
            estimatedMinutes: 15
        ),
        MaintenanceTemplate(
            id: "appliances-clean-microwave",
            title: "Deep clean microwave",
            description: "Steam clean with vinegar and water. Wipe interior, turntable, and exterior.",
            category: .appliances,
            frequency: .monthly,
            difficulty: .easy,
            estimatedMinutes: 10
        ),
        MaintenanceTemplate(
            id: "appliances-descale-coffee-maker",
            title: "Descale coffee maker",
            description: "Run a descaling solution through the coffee maker to remove mineral buildup.",
            category: .appliances,
            frequency: .quarterly,
            difficulty: .easy,
            estimatedMinutes: 20
        ),
        MaintenanceTemplate(
            id: "appliances-clean-water-filter",
            title: "Replace water filter",
            description: "Replace the refrigerator or whole-house water filter according to manufacturer schedule.",
            category: .appliances,
            frequency: .semiannual,
            difficulty: .easy,
            estimatedMinutes: 10
        ),
    ]

    // MARK: - Safety

    static let safetyTasks: [MaintenanceTemplate] = [
        MaintenanceTemplate(
            id: "safety-test-fire-extinguishers",
            title: "Test fire extinguishers",
            description: "Check the pressure gauge, inspect for damage, and verify the pin and seal are intact.",
            category: .safety,
            frequency: .monthly,
            difficulty: .easy,
            estimatedMinutes: 5
        ),
        MaintenanceTemplate(
            id: "safety-review-emergency-plan",
            title: "Review emergency plan",
            description: "Review and practice the family emergency plan including escape routes and meeting points.",
            category: .safety,
            frequency: .semiannual,
            difficulty: .easy,
            estimatedMinutes: 30
        ),
        MaintenanceTemplate(
            id: "safety-check-co-detectors",
            title: "Check carbon monoxide detectors",
            description: "Press the test button on each CO detector and verify it is within its expiration date.",
            category: .safety,
            frequency: .monthly,
            difficulty: .easy,
            estimatedMinutes: 5
        ),
        MaintenanceTemplate(
            id: "safety-check-first-aid-kit",
            title: "Check first aid kit",
            description: "Restock expired or used items in the household first aid kit.",
            category: .safety,
            frequency: .semiannual,
            difficulty: .easy,
            estimatedMinutes: 15
        ),
        MaintenanceTemplate(
            id: "safety-test-security-system",
            title: "Test security system",
            description: "Test all sensors, keypads, and the alarm to ensure the security system works properly.",
            category: .safety,
            frequency: .quarterly,
            difficulty: .easy,
            estimatedMinutes: 15
        ),
        MaintenanceTemplate(
            id: "safety-check-radon",
            title: "Test radon levels",
            description: "Use a radon test kit to check for elevated radon gas levels in the basement or ground floor.",
            category: .safety,
            frequency: .annual,
            difficulty: .easy,
            requiresBasement: true,
            estimatedMinutes: 10
        ),
        MaintenanceTemplate(
            id: "safety-inspect-handrails",
            title: "Inspect handrails and stairs",
            description: "Check all stair railings and handrails for looseness or damage. Tighten as needed.",
            category: .safety,
            frequency: .semiannual,
            difficulty: .easy,
            estimatedMinutes: 15
        ),
        MaintenanceTemplate(
            id: "safety-check-dryer-lint",
            title: "Check dryer lint trap housing",
            description: "Clean inside the lint trap housing with a long brush to remove hidden lint buildup.",
            category: .safety,
            frequency: .quarterly,
            difficulty: .easy,
            estimatedMinutes: 15
        ),
    ]

    // MARK: - Yard

    static let yardTasks: [MaintenanceTemplate] = [
        MaintenanceTemplate(
            id: "yard-mow-lawn",
            title: "Mow lawn",
            description: "Mow the lawn to the recommended height for your grass type.",
            category: .yard,
            frequency: .weekly,
            difficulty: .easy,
            season: .spring,
            requiresYard: true,
            estimatedMinutes: 45
        ),
        MaintenanceTemplate(
            id: "yard-mow-lawn-summer",
            title: "Mow lawn",
            description: "Mow the lawn to the recommended height for your grass type.",
            category: .yard,
            frequency: .weekly,
            difficulty: .easy,
            season: .summer,
            requiresYard: true,
            estimatedMinutes: 45
        ),
        MaintenanceTemplate(
            id: "yard-mow-lawn-fall",
            title: "Mow lawn",
            description: "Mow the lawn to the recommended height. Lower the blade for the final cut of the season.",
            category: .yard,
            frequency: .weekly,
            difficulty: .easy,
            season: .fall,
            requiresYard: true,
            estimatedMinutes: 45
        ),
        MaintenanceTemplate(
            id: "yard-trim-hedges",
            title: "Trim hedges and shrubs",
            description: "Trim and shape hedges and shrubs to maintain appearance and health.",
            category: .yard,
            frequency: .monthly,
            difficulty: .medium,
            season: .spring,
            requiresYard: true,
            estimatedMinutes: 60
        ),
        MaintenanceTemplate(
            id: "yard-trim-hedges-summer",
            title: "Trim hedges and shrubs",
            description: "Trim and shape hedges and shrubs to maintain appearance and health.",
            category: .yard,
            frequency: .monthly,
            difficulty: .medium,
            season: .summer,
            requiresYard: true,
            estimatedMinutes: 60
        ),
        MaintenanceTemplate(
            id: "yard-winterize-sprinklers",
            title: "Winterize sprinklers",
            description: "Drain and blow out sprinkler lines to prevent freezing and pipe damage.",
            category: .yard,
            frequency: .annual,
            difficulty: .medium,
            season: .fall,
            requiresYard: true,
            estimatedMinutes: 60
        ),
        MaintenanceTemplate(
            id: "yard-fertilize-lawn",
            title: "Fertilize lawn",
            description: "Apply appropriate seasonal fertilizer to promote healthy grass growth.",
            category: .yard,
            frequency: .seasonal,
            difficulty: .easy,
            season: .spring,
            requiresYard: true,
            estimatedMinutes: 30
        ),
        MaintenanceTemplate(
            id: "yard-rake-leaves",
            title: "Rake leaves",
            description: "Rake and dispose of fallen leaves to prevent lawn damage and pest harboring.",
            category: .yard,
            frequency: .weekly,
            difficulty: .easy,
            season: .fall,
            requiresYard: true,
            estimatedMinutes: 60
        ),
        MaintenanceTemplate(
            id: "yard-aerate-lawn",
            title: "Aerate lawn",
            description: "Aerate the lawn to reduce soil compaction and improve water and nutrient absorption.",
            category: .yard,
            frequency: .annual,
            difficulty: .medium,
            season: .fall,
            requiresYard: true,
            estimatedMinutes: 90
        ),
        MaintenanceTemplate(
            id: "yard-mulch-beds",
            title: "Mulch garden beds",
            description: "Apply fresh mulch to garden beds to retain moisture and suppress weeds.",
            category: .yard,
            frequency: .annual,
            difficulty: .medium,
            season: .spring,
            requiresYard: true,
            estimatedMinutes: 120
        ),
        MaintenanceTemplate(
            id: "yard-prune-trees",
            title: "Prune trees",
            description: "Remove dead, damaged, or crossing branches from trees.",
            category: .yard,
            frequency: .annual,
            difficulty: .hard,
            season: .winter,
            requiresYard: true,
            estimatedMinutes: 120
        ),
        MaintenanceTemplate(
            id: "yard-overseed-lawn",
            title: "Overseed lawn",
            description: "Spread grass seed over thin or bare areas to thicken the lawn.",
            category: .yard,
            frequency: .annual,
            difficulty: .easy,
            season: .fall,
            requiresYard: true,
            estimatedMinutes: 45
        ),
        MaintenanceTemplate(
            id: "yard-sharpen-mower-blade",
            title: "Sharpen mower blade",
            description: "Remove and sharpen the lawn mower blade for a clean cut.",
            category: .yard,
            frequency: .annual,
            difficulty: .medium,
            season: .spring,
            requiresYard: true,
            estimatedMinutes: 30
        ),
        MaintenanceTemplate(
            id: "yard-weed-control",
            title: "Apply weed control",
            description: "Apply pre-emergent or post-emergent weed treatment as appropriate for the season.",
            category: .yard,
            frequency: .seasonal,
            difficulty: .easy,
            season: .spring,
            requiresYard: true,
            estimatedMinutes: 30
        ),
    ]

    // MARK: - Pool

    static let poolTasks: [MaintenanceTemplate] = [
        MaintenanceTemplate(
            id: "pool-test-water-chemistry",
            title: "Test water chemistry",
            description: "Test pH, chlorine, alkalinity, and calcium hardness levels. Adjust as needed.",
            category: .pool,
            frequency: .weekly,
            difficulty: .easy,
            season: .summer,
            requiresPool: true,
            estimatedMinutes: 15
        ),
        MaintenanceTemplate(
            id: "pool-clean-skimmer-baskets",
            title: "Clean skimmer baskets",
            description: "Empty debris from skimmer and pump baskets to maintain water flow.",
            category: .pool,
            frequency: .weekly,
            difficulty: .easy,
            season: .summer,
            requiresPool: true,
            estimatedMinutes: 10
        ),
        MaintenanceTemplate(
            id: "pool-winterize",
            title: "Winterize pool",
            description: "Lower water level, add winterizing chemicals, cover the pool, and shut down equipment.",
            category: .pool,
            frequency: .annual,
            difficulty: .hard,
            season: .fall,
            requiresPool: true,
            estimatedMinutes: 180
        ),
        MaintenanceTemplate(
            id: "pool-open-pool",
            title: "Open pool for season",
            description: "Remove cover, clean, refill, start equipment, and balance water chemistry.",
            category: .pool,
            frequency: .annual,
            difficulty: .hard,
            season: .spring,
            requiresPool: true,
            estimatedMinutes: 240
        ),
        MaintenanceTemplate(
            id: "pool-vacuum-pool",
            title: "Vacuum pool",
            description: "Vacuum the pool floor and walls to remove debris and algae.",
            category: .pool,
            frequency: .weekly,
            difficulty: .easy,
            season: .summer,
            requiresPool: true,
            estimatedMinutes: 30
        ),
        MaintenanceTemplate(
            id: "pool-backwash-filter",
            title: "Backwash pool filter",
            description: "Backwash the pool filter when the pressure gauge reads 8-10 PSI above normal.",
            category: .pool,
            frequency: .biweekly,
            difficulty: .easy,
            season: .summer,
            requiresPool: true,
            estimatedMinutes: 15
        ),
        MaintenanceTemplate(
            id: "pool-brush-walls",
            title: "Brush pool walls and tile",
            description: "Brush pool walls, floor, and tile line to prevent algae and calcium buildup.",
            category: .pool,
            frequency: .weekly,
            difficulty: .easy,
            season: .summer,
            requiresPool: true,
            estimatedMinutes: 20
        ),
        MaintenanceTemplate(
            id: "pool-inspect-equipment",
            title: "Inspect pool equipment",
            description: "Check pump, filter, heater, and plumbing for leaks or unusual noises.",
            category: .pool,
            frequency: .monthly,
            difficulty: .easy,
            season: .summer,
            requiresPool: true,
            estimatedMinutes: 15
        ),
        MaintenanceTemplate(
            id: "pool-shock-pool",
            title: "Shock pool",
            description: "Add shock treatment to kill bacteria and break down contaminants.",
            category: .pool,
            frequency: .biweekly,
            difficulty: .easy,
            season: .summer,
            requiresPool: true,
            estimatedMinutes: 10
        ),
    ]

}
