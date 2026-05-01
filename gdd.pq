// Growing Degree Days — Open-Meteo, base 50°F, Jan 1 → yesterday
//
// HOW TO USE:
//   1. Open Excel → Data tab → Get Data → Blank Query.
//   2. Home → Advanced Editor. Paste the entire `let ... in ...` block
//      below (everything from `let` through `WithLocation`).
//   3. Edit the Locale and BaseTempF lines at the top to taste.
//   4. Done → Close & Load. Excel will create a refreshable table.
//   5. To refresh: Data → Refresh All  (or set Query Properties →
//      "Refresh every N minutes" / "Refresh data when opening file").
//
// On first run Excel will prompt for the privacy/credentials level for
// the three Open-Meteo hosts — choose "Anonymous" and "Public" for each
// (geocoding-api.open-meteo.com, archive-api.open-meteo.com,
// api.open-meteo.com).
//
// Sourced from the Historical Weather API
// (https://open-meteo.com/en/docs/historical-weather-api) plus the
// forecast API to cover the archive's ~5-day lag. The `source` column
// flags which days are forecast vs. finalized historical readings.

let
    Locale     = "Madison, WI",
    BaseTempF  = 50,

    Today       = Date.From(DateTime.LocalNow()),
    YearStart   = #date(Date.Year(Today), 1, 1),
    EndDate     = Date.AddDays(Today, -1),
    ArchiveEnd  = List.Min({EndDate, Date.AddDays(Today, -6)}),

    FormatDate = (d as date) as text =>
        Number.ToText(Date.Year(d)) & "-" &
        Text.PadStart(Number.ToText(Date.Month(d)), 2, "0") & "-" &
        Text.PadStart(Number.ToText(Date.Day(d)), 2, "0"),

    // --- Geocoding ---
    GeocodeRaw = Json.Document(Web.Contents(
        "https://geocoding-api.open-meteo.com",
        [RelativePath = "/v1/search",
         Headers = [#"Accept-Encoding" = "identity"],
         Query = [name = Locale, count = "1", format = "json"]]
    )),
    GeocodeResults = GeocodeRaw[results],
    First    = GeocodeResults{0},
    Lat      = Number.ToText(First[latitude]),
    Lon      = Number.ToText(First[longitude]),
    LocLabel = Text.Combine(List.RemoveNulls({
        Record.FieldOrDefault(First, "name"),
        Record.FieldOrDefault(First, "admin1"),
        Record.FieldOrDefault(First, "country")
    }), ", "),

    // --- Historical archive (Jan 1 → ~6 days ago) ---
    ArchiveTable =
        if ArchiveEnd >= YearStart then
            let
                Raw = Json.Document(Web.Contents(
                    "https://archive-api.open-meteo.com",
                    [RelativePath = "/v1/archive",
                     Headers = [#"Accept-Encoding" = "identity"],
                     Query = [
                        latitude         = Lat,
                        longitude        = Lon,
                        start_date       = FormatDate(YearStart),
                        end_date         = FormatDate(ArchiveEnd),
                        daily            = "temperature_2m_max,temperature_2m_min",
                        temperature_unit = "fahrenheit",
                        timezone         = "auto"
                     ]]
                )),
                D      = Raw[daily],
                Zipped = List.Zip({ D[time], D[temperature_2m_max], D[temperature_2m_min] }),
                Rows   = List.Transform(Zipped, each _ & {"archive"}),
                T      = Table.FromRows(Rows, {"date", "tmax_f", "tmin_f", "source"})
            in T
        else
            #table({"date", "tmax_f", "tmin_f", "source"}, {}),

    // --- Forecast API fills the archive's ~5-day tail ---
    ForecastTable =
        if EndDate > ArchiveEnd then
            let
                GapDays = Number.From(Duration.Days(EndDate - ArchiveEnd)) + 1,
                PastDays = Number.ToText(List.Min({List.Max({GapDays, 1}), 92})),
                Raw = Json.Document(Web.Contents(
                    "https://api.open-meteo.com",
                    [RelativePath = "/v1/forecast",
                     Headers = [#"Accept-Encoding" = "identity"],
                     Query = [
                        latitude         = Lat,
                        longitude        = Lon,
                        daily            = "temperature_2m_max,temperature_2m_min",
                        temperature_unit = "fahrenheit",
                        timezone         = "auto",
                        past_days        = PastDays,
                        forecast_days    = "1"
                     ]]
                )),
                D            = Raw[daily],
                Zipped       = List.Zip({ D[time], D[temperature_2m_max], D[temperature_2m_min] }),
                Rows         = List.Transform(Zipped, each _ & {"forecast"}),
                T            = Table.FromRows(Rows, {"date", "tmax_f", "tmin_f", "source"}),
                ArchiveDates = Table.Column(ArchiveTable, "date"),
                Filtered = Table.SelectRows(T, each
                    Date.FromText([date]) >= YearStart and
                    Date.FromText([date]) <= EndDate and
                    not List.Contains(ArchiveDates, [date]))
            in Filtered
        else
            #table({"date", "tmax_f", "tmin_f", "source"}, {}),

    Combined = Table.Combine({ArchiveTable, ForecastTable}),
    Sorted   = Table.Sort(Combined, {{"date", Order.Ascending}}),
    Typed    = Table.TransformColumnTypes(Sorted, {
        {"date",   type date},
        {"tmax_f", type number},
        {"tmin_f", type number},
        {"source", type text}
    }),
    WithGDD = Table.AddColumn(Typed, "gdd", each
        if [tmax_f] = null or [tmin_f] = null then null
        else List.Max({ (([tmax_f] + [tmin_f]) / 2) - BaseTempF, 0 }),
        type number),
    WithLocation = Table.AddColumn(WithGDD, "location", each LocLabel, type text)
in
    WithLocation
