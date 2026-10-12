struct S3Error: Error, Sendable, Equatable {
    var code: String
    var message: String
    var status: Int
}
