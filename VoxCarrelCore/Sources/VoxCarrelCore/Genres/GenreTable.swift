import Foundation

/// The names sources use for genres, and the built-in genre each one means.
///
/// Audible files a book under paths of category names, top name first. The same name
/// can mean different things under different top names, so the names beneath a top are
/// listed with it. Tags and subjects give names with no path; those are read by the
/// plain entry of a name.
enum GenreTable {
    /// One source name.
    struct Row: Equatable, Sendable {
        let name: String
        /// The genre the name means; nil when it only narrows the name above it
        /// ("Historical" under "Mystery") and says nothing by itself.
        let genre: String?
        /// How deep the name sits in the catalogue: 1 for a top name. A deeper name is
        /// the more specific.
        let level: Int
        /// Whether every name beneath this one means the same genre as it does.
        let isWhole: Bool
    }

    /// A top name, with the names known beneath it at any depth.
    struct Top: Equatable, Sendable {
        let name: String
        let genre: String
        let rows: [Row]
    }

    private typealias G = BuiltInGenre.Name

    private static func second(_ genre: String, whole: Bool = false, _ names: String...) -> [Row] {
        names.map { Row(name: $0, genre: genre, level: 2, isWhole: whole) }
    }

    private static func third(_ genre: String, _ names: String...) -> [Row] {
        names.map { Row(name: $0, genre: genre, level: 3, isWhole: false) }
    }

    private static func fourth(_ genre: String, _ names: String...) -> [Row] {
        names.map { Row(name: $0, genre: genre, level: 4, isWhole: false) }
    }

    /// Names that only narrow the one above them.
    private static func narrowing(_ names: String...) -> [Row] {
        names.map { Row(name: $0, genre: nil, level: 3, isWhole: false) }
    }

    private static func wording(_ genre: String, level: Int = 2, _ names: String...) -> [Row] {
        names.map { Row(name: $0, genre: genre, level: level, isWhole: false) }
    }

    // MARK: Audible's names

    static let tops: [Top] = [
        Top(name: "Arts & Entertainment", genre: G.arts, rows: second(
            G.arts,
            "Architecture", "Art", "Audio Performances & Dramatizations", "Entertainment & Performing Arts", "Music",
            "Photography")),
        Top(name: "Biographies & Memoirs", genre: G.biography, rows: second(
            G.biography,
            "Adventurers, Explorers & Survival", "Art & Literature", "Cultural & Regional",
            "Diaries & Correspondence", "Entertainment & Celebrities", "Historical", "LGBTQ+", "Military & War",
            "People with Disabilities", "Politics & Activism", "Professionals & Academics", "Religious", "Sports",
            "Women")
            + second(G.trueCrime, "True Crime")),
        Top(name: "Business & Careers", genre: G.business, rows: second(
            G.business,
            "Business Development & Entrepreneurship", "Career Success", "Management & Leadership",
            "Marketing & Sales", "Women in Business", "Workplace & Organizational Behavior")),
        Top(name: "Children's Audiobooks", genre: G.children, rows: second(
            G.children,
            "Action & Adventure", "Activities & Hobbies", "Animals & Nature", "Art", "Biographies",
            "Education & Learning", "Fairy Tales, Folk Tales & Myths", "Geography & Cultures",
            "Growing Up & Facts of Life", "History", "Holidays & Celebrations", "Humor", "Literature & Fiction",
            "Music & Performing Arts", "Mystery & Suspense", "Religions", "Science & Technology",
            "Science Fiction & Fantasy", "Sports & Outdoors", "Vehicles & Transportation")),
        Top(name: "Comedy & Humor", genre: G.humour, rows:
            second(G.biography, "Biographies & Memoirs")
            + second(G.humour, "Literature & Fiction", "Performing Arts")),
        Top(name: "Computers & Technology", genre: G.technology, rows: second(
            G.technology,
            "Computer Science", "Content Creation & Social Media", "Data Science", "History & Culture",
            "Programming & Software Development", "Security & Encryption")),
        Top(name: "Education & Learning", genre: G.reference, rows: second(
            G.reference,
            "Education", "Language Learning", "Study Guides & Test Preparation", "Words, Language & Grammar",
            "Writing & Publishing")),
        Top(name: "Erotica", genre: G.romance, rows:
            second(G.romance, "Literature & Fiction")
            + second(G.health, "Sex Instruction")),
        Top(name: "Health & Wellness", genre: G.health, rows: second(
            G.health,
            "Addiction & Recovery", "Aging & Longevity", "Alternative & Complementary Medicine",
            "Beauty, Grooming & Style", "Children's Health", "Dentistry & Oral Health", "Fitness, Diet & Nutrition",
            "Hygiene & Healthy Living", "Medicine & Health Care Industry", "Physical Illness & Disease",
            "Psychology & Mental Health", "Safety & Emergency Preparedness", "Sexual & Reproductive Health")),
        Top(name: "History", genre: G.history, rows: second(
            G.history,
            "Africa", "Americas", "Ancient", "Arctic & Antarctica", "Asia", "Australia, New Zealand & Oceania",
            "Europe", "LGBTQ+", "Middle East", "Military", "Modern", "Religious", "Russia", "Women", "World")),
        Top(name: "Home & Garden", genre: G.reference, rows: second(
            G.reference,
            "Crafts & Hobbies", "Food & Wine", "Gardening & Horticulture", "House & Home", "Pets & Animal Care",
            "Sustainable & Green Living")),
        Top(name: "LGBTQ+", genre: G.politics, rows:
            second(G.biography, "Biographies & Memoirs")
            + second(G.history, "History")
            + second(G.politics, "LGBTQ+ Studies")
            + second(G.literary, "Literature & Fiction")
            + second(G.thrillers, "Mystery, Thriller & Suspense")
            + second(G.selfDevelopment, "Parenting & Families")
            + second(G.romance, "Romance")
            + second(G.scienceFiction, "Science Fiction & Fantasy")
            + third(G.crime, "Mystery")
            + third(G.thrillers, "Thriller & Suspense")
            + third(G.fantasy, "Fantasy")
            + third(G.scienceFiction, "Science Fiction")
            + third(G.romance, "Erotica")
            + third(G.literary, "Genre Fiction")
            + narrowing("Anthologies & Short Stories")),
        Top(name: "Literature & Fiction", genre: G.literary, rows:
            second(
                G.literary,
                "Action & Adventure", "African American", "Anthologies & Short Stories", "Drama & Plays", "Essays",
                "Genre Fiction", "LGBTQ+", "Literary History & Criticism", "Poetry", "Women's Fiction",
                "World Literature")
            + second(G.classics, whole: true, "Ancient, Classical & Medieval Literature")
            + second(G.classics, "Classics")
            + second(G.romance, whole: true, "Erotica")
            + second(G.historical, whole: true, "Historical Fiction")
            + second(G.horror, whole: true, "Horror")
            + second(G.humour, "Humor & Satire")
            + second(G.biography, "Memoirs, Diaries & Correspondence")
            + third(G.fantasy, "Fantasy")
            + third(G.thrillers, "Mystery, Thriller & Suspense", "Thriller & Suspense", "Domestic Thrillers")
            + third(G.romance, "Romance")
            + third(G.scienceFiction, "Science Fiction", "Dystopian")
            + third(G.crime, "Mystery")
            + third(G.horror, "Ghosts", "Gothic", "Occult")
            + third(G.humour, "Dark Humor", "Satire")
            + third(G.classics, "Shakespeare")
            + third(
                G.literary,
                "War & Military", "Women's Adventure", "Anthologies", "Short Stories", "Absurdist",
                "Alternate History", "Animals", "Biographical Fiction", "Christian Fiction", "City Life",
                "Coming of Age", "Contemporary Fiction", "Epistolary", "Family Life", "Friendship", "Holidays",
                "Literary Fiction", "Magical Realism", "Mash-Ups", "Medical", "Metaphysical & Visionary",
                "Movie, TV & Video Game Tie-Ins", "Political", "Psychological", "Sagas", "Sea Adventures",
                "Small Town & Rural", "Sports", "Suburban", "Urban", "Westerns")
            + narrowing(
                "20th Century", "Ancient", "Ancient, Classical & Medieval", "Asian", "Biographical", "Christian",
                "Collections", "Collections & Anthologies", "Comedy", "Contemporary", "Drama", "European",
                "Historical", "Indigenous", "Jewish", "Medieval", "Middle Eastern", "Religious & Liturgical",
                "Renaissance", "Romantic", "Russian & Soviet", "Science Fiction & Fantasy", "Themes & Styles",
                "Thrillers", "Tragedy", "Tragicomedy", "United States")),
        Top(name: "Money & Finance", genre: G.money, rows: second(
            G.money,
            "Banks & Banking", "Corporate & Public Finance", "E-Commerce", "Economics", "Insurance",
            "International", "Investing & Trading", "Personal Finance", "Real Estate", "Taxation")),
        Top(name: "Mystery, Thriller & Suspense", genre: G.thrillers, rows:
            second(G.crime, "Crime Fiction", "Mystery")
            + second(G.thrillers, "Thriller & Suspense")
            + second(G.trueCrime, whole: true, "True Crime")
            + third(
                G.crime,
                "Noir", "Serial Killers", "Amateur Sleuths", "Cozy", "Hard-Boiled",
                "International Mystery & Crime", "Police Procedurals", "Private Investigators",
                "Traditional Detectives", "Women Sleuths", "Modern Detectives", "Crime Thrillers")
            + third(
                G.thrillers,
                "Domestic Thrillers", "Legal", "Medical & Forensic", "Military", "Psychological",
                "Romantic Suspense", "Spies & Politics", "Supernatural", "Suspense", "Technothrillers")
            + third(
                G.trueCrime,
                "Con Artists, Hoaxes & Deceptions", "Heists & Robberies", "Murder", "Organized Crime",
                "Sexual Crimes & Assault")
            + fourth(G.thrillers, "Espionage", "Political")
            + narrowing(
                "Action & Adventure", "Anthologies & Short Stories", "Christian", "Dramatizations", "Historical",
                "LGBTQ+", "Thrillers")),
        Top(name: "Politics & Social Sciences", genre: G.politics, rows:
            second(G.politics, "Anthropology", "Law", "Politics & Government", "Social Sciences", "Sociology")
            + second(G.history, "Archaeology")
            + second(G.philosophy, "Philosophy")
            + third(
                G.politics,
                "Civics & Citizenship", "Freedom & Security", "Ideologies & Doctrines", "International Relations",
                "Labor & Industrial Relations", "Political Science", "Public Policy", "War & Crisis",
                "Women in Politics")
            + fourth(G.politics, "National & International Security", "Arms Control")),
        Top(name: "Relationships, Parenting & Personal Development", genre: G.selfDevelopment, rows: second(
            G.selfDevelopment,
            "Parenting & Families", "Personal Development", "Relationships")),
        Top(name: "Religion & Spirituality", genre: G.philosophy, rows: second(
            G.philosophy,
            "Agnosticism", "Atheism", "Buddhism", "Christianity", "Hinduism", "Islam", "Judaism", "Occult",
            "Other Religions, Practices & Sacred Texts", "Religious Studies", "Spirituality")),
        Top(name: "Romance", genre: G.romance, rows: second(
            G.romance,
            "Action & Adventure", "Anthologies & Short Stories", "Christian", "Clean & Wholesome", "Contemporary",
            "Erotica", "Fantasy", "Historical", "LGBTQ+", "Military", "Multicultural", "Paranormal",
            "Romantic Comedy", "Romantic Suspense", "Royalty", "Science Fiction", "Sports", "Westerns")),
        Top(name: "Science & Engineering", genre: G.science, rows:
            second(G.technology, "Engineering")
            + second(G.science, "Mathematics", "Science")),
        Top(name: "Science Fiction & Fantasy", genre: G.scienceFiction, rows:
            second(G.fantasy, "Fantasy")
            + second(G.scienceFiction, "Science Fiction")
            + third(
                G.fantasy,
                "Dragons & Mythical Creatures", "Epic", "Fairy Tales", "Gaslamp", "Paranormal & Urban",
                "Sword & Sorcery")
            + third(
                G.scienceFiction,
                "Cyberpunk", "Dystopian", "First Contact", "Genetic Engineering", "Hard Science Fiction",
                "Post-Apocalyptic", "Space Exploration", "Space Opera", "Steampunk", "Time Travel")
            + narrowing(
                "Action & Adventure", "Adventure", "Alternate History", "Anthologies & Short Stories", "Christian",
                "Coming of Age", "Dramatizations", "Historical", "Humorous", "LGBTQ+", "Military",
                "Movie, TV & Video Game Tie-Ins", "Romantic", "Superhero")),
        Top(name: "Sports & Outdoors", genre: G.sports, rows:
            second(G.biography, "Biographies & Memoirs")
            + second(
                G.sports,
                "Adventurers, Explorers & Survival", "Baseball & Softball", "Basketball",
                "Bodybuilding & Strength Training", "Coaching", "Combat Sports & Self-Defense", "Cricket", "Cycling",
                "Equestrian Sports", "Extreme Sports", "Football", "Golf", "Hockey", "Motor Sports",
                "Olympics & Paralympics", "Outdoors & Nature", "Rugby", "Running & Jogging", "Soccer",
                "Sociology of Sports", "Sports History", "Sports Psychology", "Sports Writing", "Tennis",
                "Track & Field", "Triathlon", "Volleyball", "Walking", "Water Sports", "Winter Sports", "Workouts")),
        Top(name: "Teen & Young Adult", genre: G.youngAdult, rows: second(
            G.youngAdult,
            "Arts & Entertainment", "Biographies", "Education & Learning", "Health, Lifestyle & Relationships",
            "History & Culture", "LGBTQ+", "Literature & Fiction", "Mystery, Thriller & Suspense",
            "Politics, Society & Current Events", "Religion & Spirituality", "Romance", "Science & Technology",
            "Science Fiction & Fantasy", "Sports & Outdoors")),
        Top(name: "Travel & Tourism", genre: G.travel, rows: second(
            G.travel,
            "Adventure Travel", "Africa", "Asia", "Australia & Oceania", "Caribbean", "Central & South America",
            "Europe", "Guided Tours", "Middle East", "North America", "Polar Regions", "Russia",
            "Travel Writing & Commentary")),
    ]

    // MARK: Plain wordings

    /// What a name means with no path above it: the wordings of tags and subjects, and
    /// the plain meaning of each catalogue name that means different things in
    /// different places. A top name is its own plain entry and is not listed here.
    static let plain: [Row] =
        wording(
            G.literary,
            "Fiction", "General Fiction", "Fiction & Literature", "Literature", "Literary", "Action & Adventure",
            "Adventure", "Adventure stories", "Anthologies & Short Stories", "Drama", "Western", "Westerns")
        + wording(G.classics, "Classic", "Classic Literature")
        + wording(
            G.crime,
            "Crime", "Mysteries", "Detective", "Detectives", "Detective and mystery stories", "Detective fiction",
            "Mystery fiction", "Mysteries & Detectives")
        + wording(
            G.thrillers,
            "Thriller", "Thrillers", "Thrillers & Suspense", "Suspense fiction", "Spy", "Spies", "Spy stories",
            "Spy fiction", "Mystery/Thriller", "Mystery & Thriller", "Mysteries & Thrillers", "Mystery & Suspense",
            "Technothriller")
        + wording(G.thrillers, level: 3, "Military", "Psychological")
        + wording(G.thrillers, level: 4, "Political")
        + wording(
            G.scienceFiction,
            "Science Fiction", "Sci-Fi", "SciFi", "Sci Fi", "SF", "Science-Fiction", "Sci-Fi & Fantasy")
        + wording(G.fantasy, "Fantasy", "Fantasy fiction")
        + wording(G.historical, "Historical", "Historical novels")
        + wording(G.romance, "Romance fiction", "Love stories", "Romantic Suspense")
        + wording(G.horror, "Horror fiction", "Horror tales", "Horror stories")
        + wording(G.humour, "Humor", "Comedy", "Humorous", "Humorous fiction", "Humorous stories")
        + wording(
            G.biography,
            "Biography", "Biographies", "Autobiography", "Autobiographies", "Memoir", "Memoirs",
            "Biography & Autobiography", "Adventurers, Explorers & Survival")
        + wording(
            G.history,
            "History & Culture", "Military History", "World History", "Africa", "Asia", "Europe", "Middle East",
            "Russia")
        + wording(
            G.politics,
            "Politics", "Current Events", "Politics & Current Events", "Politics, Society & Current Events",
            "Social Science", "Society", "Women")
        + wording(
            G.business,
            "Business", "Business & Economics", "Business & Personal Finance", "Careers", "Management",
            "Leadership", "Marketing", "Entrepreneurship")
        + wording(G.money, "Finance", "Investments", "Investing", "Money")
        + wording(G.science, "Nature", "Science & Technology", "Animals & Nature", "Physics", "Biology", "Astronomy")
        + wording(G.technology, "Technology", "Computers", "Programming")
        + wording(G.health, "Health", "Health & Fitness", "Psychology", "Medicine", "Mental Health")
        + wording(
            G.selfDevelopment,
            "Self-Help", "Self Help", "Self-Improvement", "Self Improvement", "Self Development",
            "Personal Growth", "Parenting")
        + wording(G.philosophy, "Religion", "Religions", "Religious", "Christian", "Occult", "Theology")
        + wording(G.arts, "Art", "Arts", "Performing Arts", "Music & Performing Arts", "Film")
        + wording(G.travel, "Travel", "Travel & Adventure")
        + wording(G.sports, "Sports", "Sports & Recreation", "Outdoors")
        + wording(G.reference, "Reference", "Languages", "Study Aids")
        + wording(
            G.children,
            "Kids", "Children's", "Childrens", "Children's Books", "Children's fiction", "Children's stories",
            "Juvenile fiction", "Juvenile nonfiction", "Juvenile literature", "Kids & Young Adults")
        + wording(G.youngAdult, "YA", "Young Adult Fiction", "Teen", "Teens")

    /// Wording that says nothing about what a book is about.
    static let sayNothing: [String] = [
        "Audiobook", "Audiobooks", "Audio Book", "Book", "Books", "Ebook", "Podcast", "Unknown", "Other", "Misc",
        "General", "Unabridged", "Abridged", "Non-Fiction", "Nonfiction", "Non Fiction",
    ]

    /// The genre names of ID3 tags, which files may give by number.
    static let id3Names: [String] = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal",
        "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial",
        "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal",
        "Jazz+Funk", "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip",
        "Gospel", "Noise", "AlternRock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop",
        "Instrumental Rock", "Ethnic", "Gothic", "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk",
        "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40", "Christian Rap", "Pop/Funk",
        "Jungle", "Native American", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes", "Trailer", "Lo-Fi",
        "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock",
        "Folk", "Folk-Rock", "National Folk", "Swing", "Fast Fusion", "Bebob", "Latin", "Revival", "Celtic",
        "Bluegrass", "Avantgarde", "Gothic Rock", "Progressive Rock", "Psychedelic Rock", "Symphonic Rock",
        "Slow Rock", "Big Band", "Chorus", "Easy Listening", "Acoustic", "Humour", "Speech", "Chanson", "Opera",
        "Chamber Music", "Sonata", "Symphony", "Booty Bass", "Primus", "Porn Groove", "Satire", "Slow Jam", "Club",
        "Tango", "Samba", "Folklore", "Ballad", "Power Ballad", "Rhythmic Soul", "Freestyle", "Duet", "Punk Rock",
        "Drum Solo", "A capella", "Euro-House", "Dance Hall", "Goa", "Drum & Bass", "Club-House", "Hardcore",
        "Terror", "Indie", "BritPop", "Afro-Punk", "Polsk Punk", "Beat", "Christian Gangsta Rap", "Heavy Metal",
        "Black Metal", "Crossover", "Contemporary Christian", "Christian Rock", "Merengue", "Salsa",
        "Thrash Metal", "Anime", "JPop", "Synthpop", "Abstract", "Art Rock", "Baroque", "Bhangra", "Big Beat",
        "Breakbeat", "Chillout", "Downtempo", "Dub", "EBM", "Eclectic", "Electro", "Electroclash", "Emo",
        "Experimental", "Garage", "Global", "IDM", "Illbient", "Industro-Goth", "Jam Band", "Krautrock",
        "Leftfield", "Lounge", "Math Rock", "New Romantic", "Nu-Breakz", "Post-Punk", "Post-Rock", "Psytrance",
        "Shoegaze", "Space Rock", "Trop Rock", "World Music", "Neoclassical", "Audiobook", "Audio Theatre",
        "Neue Deutsche Welle", "Podcast", "Indie Rock", "G-Funk", "Dubstep", "Garage Rock", "Psybient",
    ]

    // MARK: Matching

    /// A piece of text for matching: lower case, "&" as "and", curly apostrophes made
    /// straight, runs of spaces made one, none at the ends.
    static func pieceKey(_ text: some StringProtocol) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count + 4)
        for character in text.lowercased() {
            switch character {
            case "&": out += " and "
            case "\u{2018}", "\u{2019}": out.append("'")
            default: out.append(character)
            }
        }
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A whole name for matching, with the pieces around its commas and slashes each
    /// made a `pieceKey` and the spaces around those marks dropped.
    static func key(_ name: String) -> String {
        var out = ""
        var piece = ""
        for character in name {
            if character == "," || character == "/" {
                out += pieceKey(piece)
                out.append(character)
                piece = ""
            } else {
                piece.append(character)
            }
        }
        return out + pieceKey(piece)
    }

    /// What a name means with no path above it.
    struct Meaning: Equatable, Sendable {
        /// Nil when the name says nothing by itself.
        var genre: String?
        var level: Int
        /// The key of the top name this is, when it is one.
        var top: String?
        /// The keys of the top names this name sits under with the same meaning.
        var under: [String]
    }

    /// The table laid out for looking names up. Built once, in the order the table is
    /// written, so that nothing depends on the order of a dictionary.
    struct Index: Sendable {
        /// Where each top name is in `tops`, by key.
        private(set) var topPlaces: [String: Int] = [:]
        /// The rows beneath each top, by key, in the order of `tops`.
        private(set) var rows: [[String: Row]] = []
        private(set) var meanings: [String: Meaning] = [:]
        private(set) var sayNothing: Set<String> = []
        /// The most pieces, parted by commas and slashes, that any known name has.
        private(set) var longestName = 1
        /// Names that mean different genres under different tops and have no plain entry.
        private(set) var conflicts: [String] = []
        /// Names written twice where once is meant.
        private(set) var duplicates: [String] = []

        init() {
            var names: [(key: String, name: String)] = []
            for (place, top) in GenreTable.tops.enumerated() {
                let topKey = GenreTable.key(top.name)
                if topPlaces.updateValue(place, forKey: topKey) != nil { duplicates.append(top.name) }
                names.append((topKey, top.name))
                var beneath: [String: Row] = [:]
                for row in top.rows {
                    let rowKey = GenreTable.key(row.name)
                    if beneath.updateValue(row, forKey: rowKey) != nil {
                        duplicates.append("\(top.name) > \(row.name)")
                    }
                    names.append((rowKey, row.name))
                }
                rows.append(beneath)
            }

            var plainRows: [String: Row] = [:]
            for row in GenreTable.plain {
                let rowKey = GenreTable.key(row.name)
                if plainRows.updateValue(row, forKey: rowKey) != nil || topPlaces[rowKey] != nil {
                    duplicates.append(row.name)
                }
                names.append((rowKey, row.name))
            }
            sayNothing = Set(GenreTable.sayNothing.map(GenreTable.key))

            for (nameKey, name) in names where meanings[nameKey] == nil {
                // Every row of this name beneath a top, in the table's order.
                var beneath: [(top: String, row: Row)] = []
                for (place, top) in GenreTable.tops.enumerated() {
                    if let row = rows[place][nameKey] { beneath.append((GenreTable.key(top.name), row)) }
                }
                var meaning = Meaning(genre: nil, level: 2, top: nil, under: [])
                if let row = plainRows[nameKey] {
                    meaning.genre = row.genre
                    meaning.level = row.level
                } else if let place = topPlaces[nameKey] {
                    meaning.genre = GenreTable.tops[place].genre
                    meaning.top = nameKey
                } else if let first = beneath.first(where: { $0.row.genre != nil }) {
                    meaning.genre = first.row.genre
                    meaning.level = first.row.level
                    if beneath.contains(where: { $0.row.genre != nil && $0.row.genre != first.row.genre }) {
                        conflicts.append(name)
                    }
                }
                meaning.under = beneath.filter { $0.row.genre == meaning.genre && $0.top != nameKey }.map(\.top)
                if meaning.genre == nil { meaning.under = [] }
                meanings[nameKey] = meaning
                longestName = max(longestName, nameKey.filter { $0 == "," || $0 == "/" }.count + 1)
            }

            // The list's own names mean themselves, where no source name is spelled the same.
            for genre in BuiltInGenre.all {
                let nameKey = GenreTable.key(genre.name)
                if let known = meanings[nameKey] {
                    if known.genre != genre.name { conflicts.append(genre.name) }
                } else {
                    meanings[nameKey] = Meaning(genre: genre.name, level: 2, top: nil, under: [])
                }
            }
        }
    }

    static let index = Index()

    /// The top name with this key, and its place in `tops`.
    static func top(key: String) -> (place: Int, top: Top)? {
        index.topPlaces[key].map { ($0, tops[$0]) }
    }

    /// The row of a name beneath a top name; nil when the table has none.
    static func row(_ name: String, under top: String) -> Row? {
        guard let place = index.topPlaces[key(top)] else { return nil }
        return index.rows[place][key(name)]
    }

    /// What a name means with no path above it; nil when the table does not know it.
    static func meaning(key: String) -> Meaning? {
        index.meanings[key]
    }

    static func saysNothing(key: String) -> Bool {
        index.sayNothing.contains(key)
    }
}
