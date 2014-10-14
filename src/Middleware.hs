{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Middleware where

import Data.Aeson ((.=), toJSON, ToJSON, object, encode)
import Data.Maybe (fromMaybe)
import Data.Monoid (mconcat)

import Database.HDBC (runRaw)
import Database.HDBC.PostgreSQL (Connection)
import Database.HDBC.Types (SqlError(..))

import Data.String.Conversions(cs)
import qualified Data.ByteString.Char8 as BS
import Control.Exception (finally, throw, catchJust, catch, SomeException,
    bracket_)

import Network.HTTP.Types.Header (RequestHeaders, hContentType, hAuthorization,
  hLocation)
import Network.HTTP.Types.Status (status400, status401, status301)
import Network.Wai (Application, requestHeaders, responseLBS, rawPathInfo,
                   rawQueryString, isSecure)
import Network.URI (URI(..), parseURI)

import PgQuery(LoginAttempt(..), signInRole, setRole, resetRole)
import Codec.Binary.Base64.String (decode)

inTransaction :: (Connection -> Application) -> Connection -> Application
inTransaction app conn req respond =
  finally (runRaw conn "begin" >> app conn req respond) (runRaw conn "commit")

withSavepoint :: (Connection -> Application) -> Connection -> Application
withSavepoint app conn req respond = do
  runRaw conn "savepoint req_sp"
  catch (app conn req respond) (\e -> let _ = (e::SomeException) in
    runRaw conn "rollback to savepoint req_sp" >> throw e)

authenticated :: BS.ByteString -> (Connection -> Application) ->
                 Connection -> Application
authenticated anon app conn req respond = do
  attempt <- httpRequesterRole (requestHeaders req)
  case attempt of
    MalformedAuth ->
      respond $ responseLBS status400 [] "Malformed basic auth header"
    LoginFailed ->
      respond $ responseLBS status401 [] "Invalid username or password"
    LoginSuccess role ->
      bracket_ (setRole conn role) (resetRole conn) $ app conn req respond
    NoCredentials ->
      bracket_ (setRole conn anon) (resetRole conn) $ app conn req respond

 where
   httpRequesterRole :: RequestHeaders -> IO LoginAttempt
   httpRequesterRole hdrs = do
    let auth = fromMaybe "" $ lookup hAuthorization hdrs
    case BS.split ' ' (cs auth) of
      ("Basic" : b64 : _) ->
        case BS.split ':' $ cs (decode $ cs b64) of
          (u:p:_) -> signInRole u p conn
          _ -> return MalformedAuth
      _ -> return NoCredentials

instance ToJSON SqlError where
  toJSON t = object [
      "error" .= object [
          "code"    .= seNativeError t
        , "message" .= seErrorMsg t
        , "state"   .= seState t
      ]
    ]

clientErrors :: Application -> Application
clientErrors app req respond =
  catchJust isPgException (app req respond) (
      respond . responseLBS status400 [(hContentType, "application/json")]
              . encode
    )

  where
    isPgException :: SqlError -> Maybe SqlError
    isPgException = Just


redirectInsecure :: Application -> Application
redirectInsecure app req respond = do
  let hdrs = requestHeaders req
      host = lookup "host" hdrs
      uriM = parseURI . cs =<< mconcat [
        Just "https://",
        host,
        Just $ rawPathInfo req,
        Just $ rawQueryString req]
      isHerokuSecure = lookup "x-forwarded-proto" hdrs == Just "https"

  if not (isSecure req || isHerokuSecure)
    then case uriM of
              Just uri ->
                respond $ responseLBS status301 [
                    (hLocation, cs . show $ uri { uriScheme = "https:" })
                  ] ""
              Nothing ->
                respond $ responseLBS status400 [] "SSL is required"
    else app req respond
