// Uso: swiftc -parse-as-library Sources/iLand/S3.swift test_s3.swift -o /tmp/t_s3 && /tmp/t_s3
import Foundation

@main struct S3Check {
    static func main() {
        // Vetor oficial da AWS (suíte de testes do SigV4, "get-vanilla"): serviço "service", us-east-1.
        let c1 = S3Credentials(accessKey: "AKIDEXAMPLE", secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
        let a = SigV4.authorization(method: "GET", path: "/", headers: ["host": "example.amazonaws.com", "x-amz-date": "20150830T123600Z"],
                                    payloadHash: SigV4.sha256Hex(Data()), creds: c1, region: "us-east-1", service: "service", amzDate: "20150830T123600Z")
        assert(a == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31", a)

        // Vetor oficial do S3 (link assinado): GET /test.txt, examplebucket, 24 h.
        let c2 = S3Credentials(accessKey: "AKIAIOSFODNN7EXAMPLE", secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
        let q = SigV4.presignQuery(host: "examplebucket.s3.amazonaws.com", path: "/test.txt", creds: c2, region: "us-east-1", expires: 86400, amzDate: "20130524T000000Z")
        assert(q.hasSuffix("X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"), q)

        // Codificação e chave do objeto.
        assert(SigV4.encode("a b/ç~.-_") == "a%20b%2F%C3%A7~.-_" && SigV4.encode("a b/c", keepSlash: true) == "a%20b/c")
        let k = S3Client.objectKey(prefix: "/prints", now: Date(timeIntervalSince1970: 1_790_000_000))
        assert(k.hasPrefix("prints/print-") && k.hasSuffix(".png") && !k.hasPrefix("/"), k)
        assert(S3Client.objectKey(prefix: "").hasPrefix("print-"))
        assert(SigV4.amzDate(Date(timeIntervalSince1970: 1_369_353_600)) == "20130524T000000Z")

        // Endereço: virtual-hosted, regional e bucket com ponto (estilo de caminho).
        let cfg = S3Config(bucket: "meu-bucket", region: "sa-east-1", prefix: "p/", expiresHours: 24)
        assert(S3Target(config: cfg, key: "p/x.png").host == "meu-bucket.s3.sa-east-1.amazonaws.com" && S3Target(config: cfg, key: "p/x.png").path == "/p/x.png")
        var east = cfg; east.region = "us-east-1"
        assert(S3Target(config: east, key: "x.png").host == "meu-bucket.s3.amazonaws.com")
        var dotted = cfg; dotted.bucket = "a.b.c"
        assert(S3Target(config: dotted, key: "x.png").host == "s3.sa-east-1.amazonaws.com" && S3Target(config: dotted, key: "x.png").path == "/a.b.c/x.png")
        assert(S3Config().isComplete == false && cfg.isComplete)
        for bad in ["Bucket", "ab", "a/b", "x#y", "meu bucket", "-abc", "abc-", "evil.com/x?"] { var c = cfg; c.bucket = bad; assert(!c.isComplete, "bucket inválido: \(bad)") }
        for bad in ["us-east-1/x", "evil.com#", "us@evil.com", "", "USEAST1", "a@b"] { var c = cfg; c.region = bad; assert(!c.isComplete, "região inválida: \(bad)") }
        for ok in ["us-east-1", "sa-east-1", "eu-central-1", "ap-southeast-2", "us-gov-west-1"] { var c = cfg; c.region = ok; assert(c.isComplete, "região válida: \(ok)") }

        // Serviço compatível (R2, MinIO, Backblaze): endpoint próprio, estilo de caminho, porta no host.
        var r2 = S3Config(bucket: "meu-bucket", region: "auto", prefix: "p/", expiresHours: 24); r2.endpoint = "https://abc123.r2.cloudflarestorage.com"
        let t2 = S3Target(config: r2, key: "p/x.png")
        assert(r2.isComplete && t2.host == "abc123.r2.cloudflarestorage.com" && t2.path == "/meu-bucket/p/x.png" && t2.url.absoluteString == "https://abc123.r2.cloudflarestorage.com/meu-bucket/p/x.png")
        var minio = r2; minio.endpoint = "http://localhost:9000"; minio.region = "us-east-1"
        assert(minio.isComplete && S3Target(config: minio, key: "x.png").host == "localhost:9000" && S3Target(config: minio, key: "x.png").url.scheme == "http")
        for bad in ["http://evil.com", "ftp://x.com", "https://user@x.com", "https://x.com/path", "https://x.com?a=1", "https://", "javascript:alert(1)"] { var c = r2; c.endpoint = bad; assert(!c.isComplete, "endpoint inválido: \(bad)") }
        var badRegion = r2; badRegion.region = "AU TO"; assert(!badRegion.isComplete)

        // Links: assinado, público (com e sem base) e sem link.
        let creds = S3Credentials(accessKey: "AKIDEXAMPLE", secret: "secret")
        let date = "20260101T000000Z"
        var pub = cfg; pub.sharing = "public"; pub.publicBase = "https://cdn.exemplo.com/img"
        assert(S3Client.link(config: pub, target: S3Target(config: pub, key: "p/a b.png"), creds: creds, key: "p/a b.png", date: date).absoluteString == "https://cdn.exemplo.com/img/p/a%20b.png")
        pub.publicBase = ""
        assert(S3Client.link(config: pub, target: S3Target(config: pub, key: "p/x.png"), creds: creds, key: "p/x.png", date: date).absoluteString == "https://meu-bucket.s3.sa-east-1.amazonaws.com/p/x.png")
        var none = cfg; none.sharing = "none"
        assert(S3Client.link(config: none, target: S3Target(config: none, key: "x.png"), creds: creds, key: "x.png", date: date).query == nil)
        let signed = S3Client.link(config: cfg, target: S3Target(config: cfg, key: "x.png"), creds: creds, key: "x.png", date: date)
        assert(signed.query?.contains("X-Amz-Signature=") == true && signed.query?.contains("X-Amz-Expires=86400") == true)

        // Configuração antiga (sem os campos novos) continua valendo.
        let old = Data(#"{"bucket":"meu-bucket","region":"sa-east-1","prefix":"p/","expiresHours":12}"#.utf8)
        let decoded = try! JSONDecoder().decode(S3Config.self, from: old)
        assert(decoded.expiresHours == 12 && decoded.enabled && decoded.endpoint.isEmpty && decoded.sharing == "presigned" && decoded.isComplete)
        let round = try! JSONDecoder().decode(S3Config.self, from: JSONEncoder().encode(r2))
        assert(round == r2)

        // Mensagem de erro: só Code e Message.
        let xml = "<?xml version=\"1.0\"?><Error><Code>AccessDenied</Code><Message>Access Denied</Message><RequestId>ABC</RequestId><HostId>secretish</HostId></Error>"
        assert(S3Error.message(from: Data(xml.utf8)) == "AccessDenied - Access Denied" && S3Error.message(from: nil) == "")
        print("ok")
    }
}
