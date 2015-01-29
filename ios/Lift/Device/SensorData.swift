import Foundation

///
/// The device stats keys
///
enum SensorKind : Hashable {
    /// Accelerometer 0xad
    case Accelerometer
    /// Gyroscope     0xbd
    case Gyroscope
    /// GPS           0xcd
    case GPS
    /// HR            0xdd
    case HeartRate
    /// Some other type
    case Other(type: UInt8)
    
    var hashValue: Int {
        get {
            switch self {
            case .Accelerometer: return 1
            case .Gyroscope: return 2
            case .GPS: return 3
            case .HeartRate: return 4
            case .Other(let x): return 21 * Int(x)
            }
        }
    }
}

func ==(lhs: SensorKind, rhs: SensorKind) -> Bool {
    switch (lhs, rhs) {
    case (.Accelerometer, .Accelerometer): return true
    case (.Gyroscope, .Gyroscope): return true
    case (.GPS, .GPS): return true
    case (.HeartRate, .HeartRate): return true
    case (.Other(let l), .Other(let r)): return l == r
        
    default: return false
    }
}

///
/// The time range
///
struct TimeRange {
    var start: CFAbsoluteTime
    var end: CFAbsoluteTime
    
    ///
    /// Intersection of ``self`` and ``that``, returning a ``TimeRange`` that contains both
    /// self and that.
    ///
    func intersect(that: TimeRange) -> TimeRange {
        fatalError("Implement me")
    }
}

///
/// Groups multiple ``SensorDataArray``s, typically received from multiple devices
///
struct SensorDataGroup {
    var sensorDataArrays: [SensorDataArrayHeader : SensorDataArray] = [:]
    
    private mutating func decode(input: NSData?, fromDeviceId id: DeviceId, at time: CFAbsoluteTime) -> Void {
        if let data = input {
            var header: lift_header?
            data.getBytes(&header, length: sizeof(lift_header))
            
            let key = SensorDataArrayHeader(sourceDeviceId: id, type: header!.type, sampleSize: header!.sample_size, samplesPerSecond: header!.samples_per_second)
            let length = Int(header!.count * header!.sample_size)
            let samples = data.subdataWithRange(NSMakeRange(sizeof(lift_header), length))
            let sensorData = SensorData(startTime: time, samples: samples)
            if var x = sensorDataArrays[key] {
                x.addSensorData(sensorData)
            } else {
                sensorDataArrays[key] = SensorDataArray(header: key, sensorData: sensorData)
            }
            
            if data.length > samples.length {
                decode(data.subdataWithRange(NSMakeRange(samples.length, data.length - samples.length)), fromDeviceId: id, at: time)
            }
        }
    }

    ///
    /// Adds raw ``data`` received from device ``id`` at some ``time``
    ///
    mutating func decodeAndAdd(data: NSData, fromDeviceId id: DeviceId, at time: CFAbsoluteTime) -> Void {
        decode(data, fromDeviceId: id, at: time)
    }
    
}

///
/// The header for sensor data. It roughly matches the ``lift_header`` C struct.
///
struct SensorDataArrayHeader : Hashable {
    /// the source deviceId
    var sourceDeviceId: DeviceId
    /// the type of data
    var type: UInt8
    /// the sample size
    var sampleSize: UInt8
    /// the number of samples per second
    var samplesPerSecond: UInt8
    
    var hashValue: Int {
        get {
            return sourceDeviceId.hashValue +
                31 * Int(type) +
                31 * Int(sampleSize) +
                31 * Int(samplesPerSecond)
        }
    }
}

func ==(lhs: SensorDataArrayHeader, rhs: SensorDataArrayHeader) -> Bool {
    return lhs.sourceDeviceId == rhs.sourceDeviceId &&
           lhs.type == rhs.type &&
           lhs.sampleSize == rhs.sampleSize &&
           lhs.samplesPerSecond == rhs.samplesPerSecond
}

///
/// Potentially gappy SDA groups a number of ``SensorData`` structures with the same ``header``.
///
struct SensorDataArray {
    /// the header
    var header: SensorDataArrayHeader
    /// the data
    var sensorDatas: [SensorData]
    
    init(header: SensorDataArrayHeader) {
        self.header = header
        sensorDatas = []
    }
    
    init(header: SensorDataArrayHeader, sensorData: SensorData) {
        self.header = header
        sensorDatas = [sensorData]
    }
    
    ///
    /// Adds another ``sensorData``
    ///
    mutating func addSensorData(sensorData: SensorData) {
        sensorDatas += [sensorData]
    }
    
    ///
    /// Computes the continuous ranges of as an array of ``TimeRange``,
    /// "compacting" the sensor data that are less than ``maximumGap`` apart.
    ///
    func continuousRanges(maximumGap: CFTimeInterval) -> [TimeRange] {
        if sensorDatas.isEmpty { return [] }
        
        var result: [TimeRange] = []
        var time = sensorDatas.first!.startTime

        for (i, sensorData) in enumerate(sensorDatas) {
            let endTime = sensorData.endTime(header.sampleSize, samplesPerSecond: header.samplesPerSecond)
            if (i + 1) < sensorDatas.count {
                // there is an element after this one: does it start within the maximumGap?
                let nextSensorData: SensorData = sensorDatas[i + 1]
                // [ SD ]  [ NSD ]
                //      ^  ^
                if nextSensorData.startTime - endTime > maximumGap {
                    // no: we have another TimeRange
                    result += [TimeRange(start: time, end: endTime)]
                    time = nextSensorData.startTime
                }
            } else {
                result += [TimeRange(start: time, end: endTime)]
            }
        }
        
        return result
    }
    
    func continuousSampleIn(maximumGap: CFTimeInterval, range: TimeRange) -> SensorData? {
        fatalError("Implement me")
    }
}

///
/// The single SensorData is the payload from the sensor received at the given ``startTime``.
///
struct SensorData {
    /// the time the block of samples was received
    var startTime: CFAbsoluteTime
    /// the samples
    var samples: NSData
    
    ///
    /// Computes the end time of the sensor data block given the
    /// ``sampleSize`` and ``samplesPerSecond``
    ///
    func duration(sampleSize: UInt8, samplesPerSecond: UInt8) -> CFTimeInterval {
        let sampleCount = samples.length / Int(sampleSize)
        return CFTimeInterval(sampleCount / Int(samplesPerSecond))
    }

    ///
    /// Computes the time range of the sensor data block given the
    /// ``sampleSize`` and ``samplesPerSecond``
    ///
    func timeRange(sampleSize: UInt8, samplesPerSecond: UInt8) -> TimeRange {
        return TimeRange(start: startTime, end: endTime(sampleSize, samplesPerSecond: samplesPerSecond))
    }

    
    ///
    /// Computes the end time of the sensor data block given the
    /// ``sampleSize`` and ``samplesPerSecond``
    ///
    func endTime(sampleSize: UInt8, samplesPerSecond: UInt8) -> CFAbsoluteTime {
        return startTime + duration(sampleSize, samplesPerSecond: samplesPerSecond)
    }
    
    ///
    /// Computes slice of samples that fall within the given time range, 
    /// allowing for up to ``maximumGap`` before and after this data.
    /// Returns the ``SensorData`` with appropriately set ``startTime`` if
    /// the ``range`` is valid, or ``nil``.
    ///
    ///                         startTime + duration + maximumGap |
    ///                                                           |
    ///                                    startTime + duration | |
    ///                                                         v v
    /// [__######################################################__]
    ///  ^ ^
    ///  | | startTime
    ///  |
    ///  | startTime - maximumGap
    ///
    func slice(range: TimeRange, maximumGap: CFTimeInterval, sampleSize: UInt8, samplesPerSecond: UInt8, gapValue: UInt8) -> SensorData? {
        
        /// Append gap of given ``length`` filled with ``gapValue`` to the ``data``
        func appendGap(length: Int, gapValue value: UInt8, toData data: NSMutableData) -> Void {
            let buf: [UInt8] = [UInt8](count: length, repeatedValue: value)
            data.appendBytes(buf, length: length)
        }

        let endTime = startTime + duration(sampleSize, samplesPerSecond: samplesPerSecond)
        let startGap = startTime - range.start
        let endGap = range.end - endTime
        
        if startGap > maximumGap || endGap > maximumGap { return nil }

        // start and length are in bytes: pointers to our ``sample``
        let start  = Int( -startGap * Double(samplesPerSecond) * Double(sampleSize) )
        let length = Int( (endTime + startGap + endGap) * Double(samplesPerSecond) * Double(sampleSize) )

        if start == 0 && length == samples.length {
            // Exact match. Notice that we do the comparison here on Ints rather than the CFAbsoluteTimes above.
            return self
        }
        
        if start > 0 && (start + length) < samples.length {
            // Range is completely within our data: no gaps
            return SensorData(startTime: startTime - startGap, samples: samples.subdataWithRange(NSMakeRange(start, length)))
        }
        
        // Allowable gaps
        let r = NSMutableData()
        if start < 0 { appendGap(-start, gapValue: gapValue, toData: r) }
        let l = min(length + start, samples.length) - max(start, 0)
        r.appendData(samples.subdataWithRange(NSMakeRange(max(start, 0), l)))
        if r.length < length {
            appendGap(length - r.length, gapValue: gapValue, toData: r)
        }
        return SensorData(startTime: startTime - startGap, samples: r)
    }
}
