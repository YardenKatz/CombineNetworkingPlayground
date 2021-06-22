import Foundation
import Combine

// created by Yarden Katz 22/6/21
// based on article by Daniel Bernal. https://danielbernal.co/writing-a-networking-library-with-combine-codable-and-swift-5/


// MARK:- Request Protocol

public enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

public protocol Request {
    var path: String { get }
    var method: HTTPMethod { get }
    var contentType: String { get }
//    var queryParams: [String: String]? { get }
    var body: [String: Any]? { get }
    var headers: [String: String]? { get }
    associatedtype ReturnType: Codable   // will be defined later when instantiating protocol
}

// using extension to define default values
extension Request {
    var method: HTTPMethod { return .get }
    var contentType: String { return "application/json" }
//    var queryParams: [String: String]? { return nil }
    var body: [String: Any]? { return nil }
    var headers: [String: String]? { return nil }
}

// utility methods to transform Request to URLSession
extension Request {
  
    /// Serializes an HTTP dictionary to a JSON Data Object
    /// - Parameter params: HTTP Paramesters dictionary
    /// - Returns: Encoded JSON
    private func RequestBodyFrom(params: [String: Any]?) -> Data? {
        guard let params = params else { return nil }
        guard let httpBody = try? JSONSerialization.data(withJSONObject: params,
                                                         options: []) else {
            return nil
        }
        return httpBody
    }
    
    /// Transforms a Request into a standard URL request
    /// - Parameter baseURL: API Base URL to be used
    /// - Returns: A ready to use URLRequest
    func AsURLRequest(baseURL: String) -> URLRequest? {
        guard var urlComponents = URLComponents(string: baseURL) else { return nil }
        urlComponents.path = "\(urlComponents.path)\(path)"
        guard let finalURL = urlComponents.url else { return nil }
        
        var request = URLRequest(url: finalURL)
        request.httpMethod = method.rawValue
        request.httpBody = RequestBodyFrom(params: body)
        request.allHTTPHeaderFields = headers
        
        return request
    }
}

//MARK:- Dispatcher - dispatches request, fetches data and decode it

enum NetworkRequestError: LocalizedError, Equatable {
    case invalidRequest
    case badRequest
    case unauthorized
    case forbidden
    case notFound
    case error4xx(_ code: Int)
    case serverError
    case error5xx(_ code: Int)
    case decodingError
    case urlSessionFailed(_ error: URLError)
    case unknownError
}

struct NetworkDispatcher {
    let urlSession: URLSession!
    
    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }
    
    /// Dispatches an URLRequest and returns a publisher
    /// - Parameter request: URLRequest
    /// - Returns: A publisher with the provided decoded data or an error
    func Dispatch<ReturnType: Codable>(request: URLRequest) -> AnyPublisher<ReturnType, NetworkRequestError> {
        return urlSession
            .dataTaskPublisher(for: request)
            .tryMap { data, response in
                // if the response is invalid throw an error
                if let response = response as? HTTPURLResponse,
                   !(200...299).contains(response.statusCode) {
                    throw HttpError(response.statusCode)
                }
                return data
            }
            .decode(type: ReturnType.self, decoder: JSONDecoder())
        // handle decoding errors
            .mapError { error in
                HandleError(error)
            }
            .eraseToAnyPublisher()
    }
}

// NetworkDispatcher helper methods
extension NetworkDispatcher {
    
    /// Parses a HTTP StatusCode and returns a proper error
    /// - Parameter statusCode: HTTP status code
    /// - Returns: Mapped Error
    private func HttpError(_ statusCode: Int) -> NetworkRequestError {
        switch statusCode {
        case 400: return .badRequest
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 402, 405...499: return .error4xx(statusCode)
        case 500: return .serverError
        case 501...599: return .error5xx(statusCode)
        default: return .unknownError
        }
    }
    
    /// Parses URLSession Publisher errors and return proper ones
    /// - Parameter error: URLSession publisher error
    /// - Returns: Readable NetworkRequestError
    private func HandleError(_ error: Error) -> NetworkRequestError {
        switch error {
        case is Swift.DecodingError:
            return .decodingError
        case let urlError as URLError:
            return.urlSessionFailed(urlError)
        case let error as NetworkRequestError:
            return error
        default:
            return .unknownError
        }
    }
}

// MARK:- APICLient Wrapper, simplifies making a request

struct APIClient {
    var baseURL: String!
    var networkDispatcher: NetworkDispatcher!
    
    init(baseURL: String,
         networkDispatcher: NetworkDispatcher = NetworkDispatcher()) {
        self.baseURL = baseURL
        self.networkDispatcher = networkDispatcher
    }
    
    /// Dispatches a Request and returns a publisher
    /// - Parameter request: Request to Dispatch
    /// - Returns: A publisher containing decoded data or an error
    func Dispatch<R: Request>(_ request: R) -> AnyPublisher<R.ReturnType, NetworkRequestError> {
        guard let urlRequest = request.AsURLRequest(baseURL: baseURL) else {
            return Fail(outputType: R.ReturnType.self, failure: NetworkRequestError.badRequest)
                .eraseToAnyPublisher()
        }
        typealias RequestPublisher = AnyPublisher<R.ReturnType, NetworkRequestError>
        let requestPublisher: RequestPublisher = networkDispatcher.Dispatch(request: urlRequest)
        return requestPublisher.eraseToAnyPublisher()
    }
}

// MARK:- Encodable extension

extension Encodable {
    var asDictionary: [String: Any] {
        guard let data = try? JSONEncoder().encode(self) else { return [:] }
        guard let dictionary = try? JSONSerialization.jsonObject(with: data,
                                                                 options: .allowFragments)
                as? [String: Any] else { return [:] }
        return dictionary
    }
}

// MARK:- testing

// model
struct Todo: Codable {
    var title: String
    var completed: Bool
}

// request. defaults to GET
struct FindTodos: Request {
    typealias ReturnType = [Todo]
    var path: String = "/todos"
}

// making a request
private var cancellables = [AnyCancellable]()
let apiClient = APIClient(baseURL: "https://jsonplaceholder.typicode.com")

apiClient.Dispatch(FindTodos())
    .sink(receiveCompletion: { _ in },
          receiveValue: { value in
            print(value)
          })
    .store(in: &cancellables)


// POST request with body

// model
struct AddTodoResponse: Codable {
    var id: Int
}

struct AddTodo: Request {
    typealias ReturnType = AddTodoResponse
    var path: String = "/todos"
    var method: HTTPMethod = .post
    var body: [String : Any]?
    
    init(body: [String: Any]) {
        self.body = body
    }
}

let todo:[String: Any] = ["title": "Test Todo", "completed": true]

// making another request
apiClient.Dispatch(AddTodo(body: todo))
    .sink(receiveCompletion: { _ in },
          receiveValue: { value in
            print(value)
          })
    .store(in: &cancellables)


// using Encodable extension to simplify post request creation
let anotherTodo: Todo = Todo(title: "Test", completed: true)

apiClient.Dispatch(AddTodo(body: anotherTodo.asDictionary))
    .sink(receiveCompletion: { _ in },
          receiveValue: { value in
            print(value)
          })
    .store(in: &cancellables)
