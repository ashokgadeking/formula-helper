import AppIntents

/// Preset bottle sizes Siri can match in a single-shot phrase
/// ("Log a 120 bottle in AvantiLog"). 10ml increments from 30 to 300 cover
/// the realistic baby bottle range. Free-form amounts still work via the
/// open-ended "Log a bottle in AvantiLog" → Siri prompts for amount path.
enum BottleAmount: Int, AppEnum {
    case ml30 = 30, ml40 = 40, ml50 = 50, ml60 = 60, ml70 = 70, ml80 = 80,
         ml90 = 90, ml100 = 100, ml110 = 110, ml120 = 120, ml130 = 130,
         ml140 = 140, ml150 = 150, ml160 = 160, ml170 = 170, ml180 = 180,
         ml190 = 190, ml200 = 200, ml210 = 210, ml220 = 220, ml230 = 230,
         ml240 = 240, ml250 = 250, ml260 = 260, ml270 = 270, ml280 = 280,
         ml290 = 290, ml300 = 300

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Bottle Amount"

    static let caseDisplayRepresentations: [BottleAmount: DisplayRepresentation] = [
        .ml30: "30", .ml40: "40", .ml50: "50", .ml60: "60", .ml70: "70",
        .ml80: "80", .ml90: "90", .ml100: "100", .ml110: "110", .ml120: "120",
        .ml130: "130", .ml140: "140", .ml150: "150", .ml160: "160", .ml170: "170",
        .ml180: "180", .ml190: "190", .ml200: "200", .ml210: "210", .ml220: "220",
        .ml230: "230", .ml240: "240", .ml250: "250", .ml260: "260", .ml270: "270",
        .ml280: "280", .ml290: "290", .ml300: "300",
    ]
}
