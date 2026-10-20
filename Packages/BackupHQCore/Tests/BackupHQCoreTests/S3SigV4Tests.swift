import XCTest
@testable import BackupHQCore

final class S3SigV4Tests: XCTestCase {
    let creds = AWSCredentials(accessKeyId: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    let date = AWSSigV4Signer.amzDateFormatter.date(from: "20130524T000000Z")!

    /// AWS docs: "GET Object" example (single chunk) from the SigV4 header-based auth page.
    func testAWSDocumentedGetObjectVector() {
        var req = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
        req.httpMethod = "GET"
        req.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        AWSSigV4Signer(credentials: creds).sign(request: &req, payloadHash: AWSSigV4Signer.emptyPayloadHash, region: "us-east-1", date: date)

        let auth = req.value(forHTTPHeaderField: "Authorization")!
        XCTAssertTrue(auth.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request"), auth)
        XCTAssertTrue(auth.contains("SignedHeaders=host;range;x-amz-content-sha256;x-amz-date"), auth)
        XCTAssertTrue(auth.hasSuffix("Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"), auth)
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-amz-date"), "20130524T000000Z")
    }

    /// AWS docs: "GET Bucket Lifecycle" example — exercises query canonicalisation (`lifecycle=`).
    func testAWSDocumentedLifecycleVector() {
        var req = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/?lifecycle")!)
        req.httpMethod = "GET"
        AWSSigV4Signer(credentials: creds).sign(request: &req, payloadHash: AWSSigV4Signer.emptyPayloadHash, region: "us-east-1", date: date)
        let auth = req.value(forHTTPHeaderField: "Authorization")!
        XCTAssertTrue(auth.hasSuffix("Signature=fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543"), auth)
    }

    /// AWS docs: "Get Bucket (List Objects)" example — two query params, sorted.
    func testAWSDocumentedListObjectsVector() {
        var req = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J")!)
        req.httpMethod = "GET"
        AWSSigV4Signer(credentials: creds).sign(request: &req, payloadHash: AWSSigV4Signer.emptyPayloadHash, region: "us-east-1", date: date)
        let auth = req.value(forHTTPHeaderField: "Authorization")!
        XCTAssertTrue(auth.hasSuffix("Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"), auth)
    }

    func testCanonicalURIEncodesSegments() {
        let url = URL(string: "https://b.s3.eu-west-1.amazonaws.com/2013/2013-03-16/My%20Photo%20%2B%20Copy%20%28a%29.DNG")!
        XCTAssertEqual(AWSSigV4Signer.canonicalURI(url), "/2013/2013-03-16/My%20Photo%20%2B%20Copy%20%28a%29.DNG")
        XCTAssertEqual(AWSSigV4Signer.canonicalURI(URL(string: "https://b.s3.amazonaws.com")!), "/")
        XCTAssertEqual(AWSSigV4Signer.awsEncode("a b/c~d*e"), "a%20b%2Fc~d%2Ae")
        XCTAssertEqual(AWSSigV4Signer.awsEncode("a b/c", keepSlash: true), "a%20b/c")
    }

    func testCanonicalQuerySortsAndEncodes() {
        let url = URL(string: "https://b.s3.amazonaws.com/?prefix=photos%2F2013&list-type=2&uploads&max-keys=10")!
        XCTAssertEqual(AWSSigV4Signer.canonicalQuery(url), "list-type=2&max-keys=10&prefix=photos%2F2013&uploads=")
    }

    func testRequestBuilderMatchesCanonicalForm() throws {
        // Round-trip: the URL the client builds must canonicalise to the same encoded path/query it sent.
        let client = S3Client(config: S3Config(region: "eu-west-1", bucket: "silas-photos"), credentials: creds)
        let key = "2013/2013-03-16/Räksmörgås (1).DNG"
        let req = try awaitSync { try await client.makeRequest(method: "PUT", key: key, query: [URLQueryItem(name: "partNumber", value: "3"), URLQueryItem(name: "uploadId", value: "a+b/c=")], headers: [:], contentType: nil) }
        let url = req.url!
        XCTAssertEqual(url.host, "silas-photos.s3.eu-west-1.amazonaws.com")
        XCTAssertEqual(url.path, "/" + key)
        XCTAssertEqual(AWSSigV4Signer.canonicalURI(url), "/2013/2013-03-16/R%C3%A4ksm%C3%B6rg%C3%A5s%20%281%29.DNG")
        XCTAssertEqual(AWSSigV4Signer.canonicalQuery(url), "partNumber=3&uploadId=a%2Bb%2Fc%3D")
    }

    func testCredentialsFileParsing() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sp-aws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".aws"), withIntermediateDirectories: true)
        try """
        [default]
        aws_access_key_id = AKIADEFAULT
        aws_secret_access_key = secretdefault

        # a comment
        [photos]
        aws_access_key_id=AKIAPHOTOS
        aws_secret_access_key = secretphotos
        aws_session_token = tok
        """.write(to: home.appendingPathComponent(".aws/credentials"), atomically: true, encoding: .utf8)
        try """
        [default]
        region = eu-west-1
        output = json
        [profile photos]
        region = us-west-2
        [profile derived]
        source_profile = photos
        region = ap-southeast-2
        """.write(to: home.appendingPathComponent(".aws/config"), atomically: true, encoding: .utf8)

        let d = try AWSCredentialsFile.load(profile: "default", home: home)
        XCTAssertEqual(d.credentials.accessKeyId, "AKIADEFAULT")
        XCTAssertEqual(d.region, "eu-west-1")
        let p = try AWSCredentialsFile.load(profile: "photos", home: home)
        XCTAssertEqual(p.credentials, AWSCredentials(accessKeyId: "AKIAPHOTOS", secretAccessKey: "secretphotos", sessionToken: "tok"))
        XCTAssertEqual(p.region, "us-west-2")
        let derived = try AWSCredentialsFile.load(profile: "derived", home: home)
        XCTAssertEqual(derived.credentials.accessKeyId, "AKIAPHOTOS")
        XCTAssertEqual(derived.region, "ap-southeast-2")
        XCTAssertEqual(AWSCredentialsFile.listProfiles(home: home), ["default", "derived", "photos"])
        XCTAssertThrowsError(try AWSCredentialsFile.load(profile: "missing", home: home))
    }

    func testErrorXMLParsing() {
        let body = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <Error><Code>PermanentRedirect</Code><Message>The bucket you are attempting to access must be addressed using the specified endpoint.</Message><Endpoint>b.s3.us-west-2.amazonaws.com</Endpoint><RequestId>ABC</RequestId></Error>
        """.utf8)
        let http = HTTPURLResponse(url: URL(string: "https://b.s3.eu-west-1.amazonaws.com/")!, statusCode: 301, httpVersion: nil, headerFields: nil)!
        let err = S3Client.error(from: http, body: body)
        XCTAssertEqual(err.code, "PermanentRedirect")
        XCTAssertTrue(err.message!.contains("us-west-2"))
        XCTAssertEqual(err.requestId, "ABC")
    }

    func testPartSizing() {
        let fileSize: Int64 = 130 * 1024 * 1024 + 7
        let partSize = S3Uploader.defaultPartSize
        let count = Int((fileSize + Int64(partSize) - 1) / Int64(partSize))
        XCTAssertEqual(count, 3)
        XCTAssertEqual(S3Uploader.expectedPartSize(1, partSize: partSize, partCount: count, fileSize: fileSize), Int64(partSize))
        XCTAssertEqual(S3Uploader.expectedPartSize(3, partSize: partSize, partCount: count, fileSize: fileSize), 2 * 1024 * 1024 + 7)
    }

    // Helper to call actor-isolated methods from a sync XCTest.
    private func awaitSync<T>(_ body: @escaping () async throws -> T) throws -> T {
        let exp = expectation(description: "async")
        var result: Result<T, Error>?
        Task { result = await Result { try await body() }; exp.fulfill() }
        wait(for: [exp], timeout: 10)
        return try result!.get()
    }
}

private extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
