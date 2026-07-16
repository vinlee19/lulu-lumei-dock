import EurekaSync
import Foundation

func sigV4Tests(_ t: TestRunner) {
    t.suite("SigV4Signer")

    // AWS 官方文档的 GET iam 签名示例（AKIDEXAMPLE / 20150830 / us-east-1 / iam）
    // 逐级断言 canonicalRequest → hash → stringToSign → signingKey → signature
    let secretKey = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"

    t.test("canonical request 与 AWS 文档示例逐字节一致") {
        let canonical = SigV4Signer.canonicalRequest(
            method: "GET", path: "/",
            query: [("Action", "ListUsers"), ("Version", "2010-05-08")],
            headers: [
                "content-type": "application/x-www-form-urlencoded; charset=utf-8",
                "host": "iam.amazonaws.com",
                "x-amz-date": "20150830T123600Z",
            ],
            payloadHash: SigV4Signer.emptyPayloadHash)
        let expected = """
        GET
        /
        Action=ListUsers&Version=2010-05-08
        content-type:application/x-www-form-urlencoded; charset=utf-8
        host:iam.amazonaws.com
        x-amz-date:20150830T123600Z

        content-type;host;x-amz-date
        e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        """
        try expectEqual(canonical, expected)
        try expectEqual(
            SigV4Signer.sha256Hex(Data(canonical.utf8)),
            "f536975d06c0309214f805bb90ccff089219ecd68b2577efef23edd43b7e1a59")
    }

    t.test("string to sign 与最终签名与 AWS 文档示例一致") {
        let scope = "20150830/us-east-1/iam/aws4_request"
        let toSign = SigV4Signer.stringToSign(
            amzDate: "20150830T123600Z", scope: scope,
            canonicalRequest: SigV4Signer.canonicalRequest(
                method: "GET", path: "/",
                query: [("Action", "ListUsers"), ("Version", "2010-05-08")],
                headers: [
                    "content-type": "application/x-www-form-urlencoded; charset=utf-8",
                    "host": "iam.amazonaws.com",
                    "x-amz-date": "20150830T123600Z",
                ],
                payloadHash: SigV4Signer.emptyPayloadHash))
        let expectedToSign = """
        AWS4-HMAC-SHA256
        20150830T123600Z
        20150830/us-east-1/iam/aws4_request
        f536975d06c0309214f805bb90ccff089219ecd68b2577efef23edd43b7e1a59
        """
        try expectEqual(toSign, expectedToSign)

        let key = SigV4Signer.signingKey(
            secretKey: secretKey, dateStamp: "20150830", region: "us-east-1", service: "iam")
        try expectEqual(
            key.hexString,
            "c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9")
        try expectEqual(
            SigV4Signer.hmacHex(key: key, message: toSign),
            "5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7")
    }

    t.test("sign() 完整输出：头齐全、scope 正确、签名为 64 位 hex") {
        let headers = SigV4Signer.sign(
            SigV4Signer.RequestToSign(
                method: "PUT", host: "Bucket.COS.ap-guangzhou.myqcloud.com",
                canonicalPath: "/eureka/host/claude/CLAUDE.md",
                payloadHash: SigV4Signer.sha256Hex(Data("hello".utf8))),
            credentials: SigV4Signer.Credentials(accessKey: "AKID", secretKey: "SK"),
            region: "ap-guangzhou",
            date: Date(timeIntervalSince1970: 1_700_000_000))
        try expect(headers["host"] == "bucket.cos.ap-guangzhou.myqcloud.com", "host 应小写化")
        try expect(headers["x-amz-date"] != nil && headers["x-amz-content-sha256"] != nil)
        let auth = headers["authorization"] ?? ""
        try expect(auth.hasPrefix("AWS4-HMAC-SHA256 Credential=AKID/"), "authorization 前缀错误：\(auth)")
        try expect(auth.contains("/ap-guangzhou/s3/aws4_request"), "scope 应含 region/s3")
        try expect(auth.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date"))
        let signature = auth.components(separatedBy: "Signature=").last ?? ""
        try expectEqual(signature.count, 64)
        try expect(signature.allSatisfy { $0.isHexDigit && (!$0.isLetter || $0.isLowercase) })
    }

    t.test("hexString 与空 payload 哈希") {
        try expectEqual(Data([0x00, 0xAB, 0xFF]).hexString, "00abff")
        try expectEqual(
            SigV4Signer.emptyPayloadHash,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    t.test("uriEncode：unreserved 保留，其余含中文逐字节大写编码") {
        try expectEqual(SigV4Signer.uriEncode("AZaz09-._~"), "AZaz09-._~")
        try expectEqual(SigV4Signer.uriEncode("a b/c"), "a%20b%2Fc")
        try expectEqual(SigV4Signer.uriEncode("中"), "%E4%B8%AD")
    }
}
