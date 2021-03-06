# Load dependencies
require('jsonlite')
require('httr')

# Sys.setenv(http_proxy="http://localhost:8888") # Enables Fiddler capturing of traffic
# Sys.setenv(http_proxy="") # Disables Fiddler proxying

# Create a simple Publish API client.
publishClient <- setRefClass("publishClient",
  fields = list(baseUri = "character", version = "character"),
  methods = list(
    #' Connects to an AQTS server
    #' 
    #' Once authenticated, all subsequent requests to the AQTS server will reuse the authenticated session
    #' 
    #' @param hostname A server name or IP address
    #' @param username The AQTS credentials username
    #' @param password The AQTS credentials password
    #' @examples 
    #' connect("localhost", "admin", "admin") # When running R on your AQTS app server
    #' connect("myserver", "me", "mypassword") # Connect over the network
    #' connect("https://myserver", "user", "letmein") # Connect to an AQTS server with HTTPS enabled
    connect = function(hostname, username, password) {
      # Support schemeless and schemed hosts for convenience
      prefix <- "http://"
      if (startsWith(hostname, "http://") || startsWith(hostname, "https://")) {
        url <- parse_url(hostname)
        hostname <- paste0(url$scheme, "://", url$hostname)
        prefix <- ""
      }
      
      # Grab the version of the AQTS server
      r <- GET(paste0(prefix, hostname, "/AQUARIUS/apps/v1/version"))
      stop_for_status(r, "detecting AQTS version")
      
      j <- fromJSON(content(r, "text"))
      version <<- j$ApiVersion

      # Compose the base URI for all Publish API requests      
      baseUri <<- paste0(prefix, hostname, "/AQUARIUS/Publish/v2")

      # Try to authenticate using the supplied credentials
      r <- POST(paste0(baseUri, "/session"), body = list(Username = username, EncryptedPassword = password), encode = "json")
      stop_for_status(r, "authenticate with AQTS")
    },
    
    #' Disconnects immediately from an AQTS server
    disconnect = function() {
      r <- DELETE(paste0(baseUri, "/session"))
      stop_for_status(r, "disconnect from AQTS")
    },
    
    #' Determines if a target version string is strictly less than a source version
    #' 
    #' This method takes dotted version strings and compares them by numerical components.
    #' It safely avoids the errors string comparison, which incorrectly says "3.10.510" > "17.2.123".
    #' @param targetVersion Target version string
    #' @param sourceVersion Optional source version string. If missing, use the connected server version
    #' @return TRUE if the target version is strictly less than the source version
    isVersionLessThan = function(targetVersion, sourceVersion) {
      if (missing(sourceVersion)) {
        sourceVersion <- version
      }
      
      # Create the vectors of integers using this local sanitizing function
      createIntegerVector <- function(versionText) {
        
        if (versionText == "0.0.0.0") {
          # Force unreleased developer builds to act as latest-n-greatest
          versionText <- "9999.99"
        }
        
        # Convert the text into a vector of integers
        v <- as.integer(strsplit(versionText, ".", fixed = TRUE)[[1]])
        
        if (length(v) > 0 && v[1] >= 14 && v[1] <= 99) {
          # Adjust the leading component to match the 20xx.y release convention
          v[1] = v[1] + 2000
        }
        
        v
      }
      
      # Convert to vectors of integers
      target <- createIntegerVector(targetVersion)
      source <- createIntegerVector(sourceVersion)
      
      # Take the differnce of the common parts
      minlength <- min(length(target), length(source))
      
      diff <- head(target, minlength) - head(source, minlength)
      
      if (all(diff == 0)) {
        # All the common parts are identical
        length(source) < length(target)
      } else {
        # Assume not less than
        lessThan <- FALSE
        
        for (d in diff) {
          if (d < 0) {
            break
          } else if (d > 0) {
            lessThan <- TRUE
            break
          }
        }
        
        lessThan
      }
    },
    
    #' Gets the unique ID of a time-series from its identifier string
    #' 
    #' If the input string is already a unique ID, the input value is simply returned unmodified.
    #' 
    #' @param identifier A time-series identifier in <Parameter>.<Label>@<LocationIdentifier> syntax
    #' @return The unique ID of the time-series
    #' @examples
    #' getTimeSeriesUniqueId("Stage.Working@MyLocation") # cdf184928c8249abb872f852f0fa7d01
    getTimeSeriesUniqueId = function(identifier) {
      if (!grepl("@", identifier)) {
        # It's not in Param.Label@Location format, so just leave it as-is
        identifier
      } else {
        # Parse out the location identifier
        location <- strsplit(identifier, "@")[[1]][[2]]
        
        # Ask for all the time-series at that location
        r <- GET(paste0(baseUri, "/GetTimeSeriesDescriptionList"), query = list(LocationIdentifier = location))
        stop_for_status(r, paste("retrieve time-series at location", location))
        
        # Find the unique ID by matching the full identifier
        j <- fromJSON(content(r, "text"))
        j$TimeSeries$UniqueId[which(j$TimeSeries$Identifier == identifier)]
      }
    },

    #' Parse an ISO 8601 timestamp into a POSIXct value
    #' 
    #' @param isoText An ISO 8601 timestamp string
    #' @return The equivalent POSIXct datetime
    #' @examples 
    #' parseIso8601("2015-04-01T00:00:00Z") # April Fool's day, 2015 UTC
    #' parseIso8601("2015-04-01T00:00:00-08:00") # April Fool's day, 2015, Pacific Standard Time
    parseIso8601 = function(isoText) {
      # Wow. Parsing true ISO 8061 timestamps (which AQTS outputs) in R is hard.
      #
      # Parsing them **efficiently** and correctly when dealing with thousands of points is even harder!
      #
      # There are many packages claiming to be compliant with ISO 8601.
      # But most are only compliant-ish(TM), failing to deal with timezones and UTC offsets
      #
      # R's strptime() method has a %z conversion specifier for timezone offsets.
      #
      # But %z only suports RFC 822 offset in: <sign><4-digits>
      #
      #  +HHMM (+1400 max)
      #  -HHMM (-1400 max)
      #
      # AQTS uses ISO 8601 offsets, either "Z" or <sign><2-digit-hour>:<2-digit-minute>
      #
      #  Z      (UTC assumed)
      #  +HH:MM (+14:00 max)
      #  -HH:MM (-12:00 min)
      #
      # This function can process roughly 10K timestamps/sec.
      # By comparison, the popular-and-otherwise-correct lubridate library is 60x slower at ~ 150 timestamps per second
      len <- nchar(isoText)
      
      if (substr(isoText, len-2, len-2) == ":") {
        # The most common scenario from AQTS output: A truly correct ISO 8601 timestamp with a numeric UTC offset
        # Strip out the colon separating the UTC offset, since that is what %z requires
        isoText <- paste0(substr(isoText, 1, len-3), substr(isoText, len-1, len))
      } else if (substr(isoText, len, len) == "Z") {
        # Second most likely scenario from AQTS output: The "Z" representing a UTC time
        # Convert the unsupported UTC shorthand into an offset with no effect
        isoText <- paste0(substr(isoText, 1, len-1), "+0000")
      }
      
      as.POSIXct(strptime(isoText, "%Y-%m-%dT%H:%M:%OS%z", "UTC"))
    },
    
    #' Formats a datetime in ISO 8601 format
    #' 
    #' @param datetime A datetime object
    #' @return The time in YYYY-MM-DDTHH:mm:SS.fffffZ format
    formatIso8601 = function(datetime) {
      strftime(datetime, "%Y-%m-%dT%H:%M:%OS%z", "UTC")
    },

    #' Gets time-series points for multiple time-series
    #' 
    #' Retrieves points for up to 10 time-series.
    #' Point values from secondary time-series will be time-aligned via interpolation
    #' rules to the timestamps from the first time-series.
    #' 
    #' @param timeSeriesIds A list of time-series identifiers or unique IDs
    #' @param queryFrom Optional time from which to retrieve data.If missing, fetches data from the start-of-record
    #' @param queryTo Optional time to which data willl be retrieved. If missing, fetches data to the end-of-record
    #' @param outputUnitIds Optional unit IDs for output. If missing or empty, the default unit of the time-series will be used
    #' @returns The JSON object from the /GetTimeSeriesData response
    #' @examples
    #' ## Get the discharge and stage timeseries for 2012
    #' json = timeseries$getTimeSeriesData(c("Discharge.Working@Location","Stage.Working@Location"),
    #'                                     queryFrom = "2012-01-01T00:00:00Z",
    #'                                     queryTo   = "2013-01-01T00:00:00Z")
    #'
    #' ## Plot stage vs dicharge
    #' plot(json$Points$NumericValue1, json$Points$NumericValue2)
    #'
    #' ## Plot stage vs dicharge, with log scale, and some labeled axis
    #' plot(json$Points$NumericValue1, json$Points$NumericValue2, log = "xy",
    #'      xlab = json$TimeSeries$Identifier[1],
    #'      ylab = json$TimeSeries$Identifier[2])
    getTimeSeriesData = function(timeSeriesIds, queryFrom, queryTo, outputUnitIds) {
      if (.self$isVersionLessThan("17.2")) {
        # Throw on the brakes if the server is too old
        stop("Time aligned data is not availble before AQTS 2017.2. Connected server version=", version)
      }
      
      uniqueIds <- lapply(timeSeriesIds, .self$getTimeSeriesUniqueId)
      
      q <- list(TimeSeriesUniqueIds = paste(uniqueIds, collapse=","))
      
      if (!missing(queryFrom)) {
        q <- c(q, QueryFrom = queryFrom)
      }           
      
      if (!missing(queryTo)) {
        q <- c(q, QueryTo = queryTo)
      }
      
      if (!missing(outputUnitIds)) {
        q <- c(q, TimeSeriesOutputUnitIds = outputUnitIds)
      }
      
      r <- GET(paste0(baseUri, "/GetTimeSeriesData"), query = q)
      stop_for_status(r, paste("get time-aligned data for", length(uniqueIds), "time-series"))
      
      j <- fromJSON(content(r, "text"))
    }
  )
)

# Create a client in the global namespace
timeseries = publishClient()
