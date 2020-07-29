module Hasura.GraphQL.Execute.Insert
  ( fmapAnnInsert
  , convertToSQLTransaction
  ) where

import           Hasura.Prelude

import qualified Data.Aeson                     as J
import qualified Data.HashMap.Strict            as Map
import qualified Data.Sequence                  as Seq
import qualified Data.Text                      as T
import qualified Database.PG.Query              as Q

import qualified Hasura.RQL.DML.Insert          as RQL
import qualified Hasura.RQL.DML.Insert.Types    as RQL
import qualified Hasura.RQL.DML.Mutation        as RQL
import qualified Hasura.RQL.DML.RemoteJoin      as RQL
import qualified Hasura.RQL.DML.Returning       as RQL
import qualified Hasura.RQL.DML.Returning.Types as RQL
import qualified Hasura.RQL.GBoolExp            as RQL
import qualified Hasura.SQL.DML                 as S

import           Hasura.Db
import           Hasura.EncJSON
import           Hasura.GraphQL.Schema.Insert
import           Hasura.RQL.Types
import           Hasura.Server.Version          (HasVersion)
import           Hasura.SQL.Types
import           Hasura.SQL.Value

-- insert translation

-- FIXME:
-- Furthermore, this has been lifted almost verbatim from Resolve
-- and is unlikely to be correct on the first try. For instance:
-- - all calls to "validate" have been removed, since everything they
--   do should be baked directly into the parsers above.
-- - some paths still throw errors; is this something we're okay with
--   or should this operation be total? what should we move to our
--   internal representation, to avoid errors here?
-- - is some of this code dead or unused? are there paths never taken?
--   can it be simplified?

fmapAnnInsert :: (a -> b) -> AnnMultiInsert a -> AnnMultiInsert b
fmapAnnInsert f (annIns, mutationOutput) =
  ( fmapMulti annIns
  , runIdentity $ RQL.traverseMutationOutput (pure . f) mutationOutput
  )
  where
    fmapMulti (AnnIns objs table conflictClause (insertCheck, updateCheck) columns defaultValues) =
      AnnIns
        (fmap fmapObject objs)
        table
        (fmap (fmap f) conflictClause)
        (fmapAnnBoolExp f insertCheck, fmap (fmapAnnBoolExp f) updateCheck)
        columns
        (fmap f defaultValues)
    fmapSingle (AnnIns obj table conflictClause (insertCheck, updateCheck) columns defaultValues) =
      AnnIns
        (fmapObject obj)
        table
        (fmap (fmap f) conflictClause)
        (fmapAnnBoolExp f insertCheck, fmap (fmapAnnBoolExp f) updateCheck)
        columns
        (fmap f defaultValues)
    fmapObject (AnnInsObj columns objRels arrRels) =
      AnnInsObj
        (fmap (fmap f) columns)
        (fmap (fmapRel fmapSingle) objRels)
        (fmap (fmapRel fmapMulti)  arrRels)
    fmapRel t (RelIns object relInfo) = RelIns (t object) relInfo


convertToSQLTransaction
  :: (HasVersion, MonadTx m, MonadIO m)
  => AnnMultiInsert S.SQLExp
  -> RQL.MutationRemoteJoinCtx
  -> Seq.Seq Q.PrepArg
  -> Bool
  -> m EncJSON
convertToSQLTransaction (annIns, mutationOutput) rjCtx planVars stringifyNum =
  if null $ _aiInsObj annIns
  then pure $ RQL.buildEmptyMutResp mutationOutput
  else insertMultipleObjects annIns [] rjCtx mutationOutput planVars stringifyNum

insertMultipleObjects
  :: (HasVersion, MonadTx m, MonadIO m)
  => MultiObjIns S.SQLExp
  -> [(PGCol, S.SQLExp)]
  -> RQL.MutationRemoteJoinCtx
  -> RQL.MutationOutput
  -> Seq.Seq Q.PrepArg
  -> Bool
  -> m EncJSON
insertMultipleObjects multiObjIns additionalColumns rjCtx mutationOutput planVars stringifyNum =
  bool withoutRelsInsert withRelsInsert anyRelsToInsert
  where
    AnnIns insObjs table conflictClause checkCondition columnInfos defVals = multiObjIns
    allInsObjRels = concatMap _aioObjRels insObjs
    allInsArrRels = concatMap _aioArrRels insObjs
    anyRelsToInsert = not $ null allInsArrRels && null allInsObjRels

    withoutRelsInsert = do
      for_ (_aioColumns <$> insObjs) \column ->
        validateInsert (map fst column) [] (map fst additionalColumns)
      let columnValues = map (mkSQLRow defVals) $ union additionalColumns . _aioColumns <$> insObjs
          columnNames  = Map.keys defVals
          insertQuery  = RQL.InsertQueryP1
            table
            columnNames
            columnValues
            conflictClause
            checkCondition
            mutationOutput
            columnInfos
      RQL.execInsertQuery stringifyNum (Just rjCtx) (insertQuery, planVars)

    withRelsInsert = do
      insertRequests <- for insObjs \obj -> do
        let singleObj = AnnIns obj table conflictClause checkCondition columnInfos defVals
        insertObject singleObj additionalColumns rjCtx planVars stringifyNum
      let affectedRows = sum $ map fst insertRequests
          columnValues = catMaybes $ map snd insertRequests
      selectExpr <- RQL.mkSelCTEFromColVals table columnInfos columnValues
      let (mutOutputRJ, remoteJoins) = RQL.getRemoteJoinsMutationOutput mutationOutput
          sqlQuery = Q.fromBuilder $ toSQL $
                     RQL.mkMutationOutputExp table columnInfos (Just affectedRows) selectExpr mutOutputRJ stringifyNum
      RQL.executeMutationOutputQuery sqlQuery [] $ (,rjCtx) <$> remoteJoins

insertObject
  :: (HasVersion, MonadTx m, MonadIO m)
  => SingleObjIns S.SQLExp
  -> [(PGCol, S.SQLExp)]
  -> RQL.MutationRemoteJoinCtx
  -> Seq.Seq Q.PrepArg
  -> Bool
  -> m (Int, Maybe (ColumnValues TxtEncodedPGVal))
insertObject singleObjIns additionalColumns rjCtx planVars stringifyNum = do
  validateInsert (map fst columns) (map _riRelInfo objectRels) (map fst additionalColumns)

  -- insert all object relations and fetch this insert dependent column values
  objInsRes <- forM objectRels $ insertObjRel planVars rjCtx stringifyNum

  -- prepare final insert columns
  let objRelAffRows = sum $ map fst objInsRes
      objRelDeterminedCols = concatMap snd objInsRes
      finalInsCols = columns <> objRelDeterminedCols <> additionalColumns

  cte <- mkInsertQ table onConflict finalInsCols defaultValues checkCond

  MutateResp affRows colVals <- liftTx $ RQL.mutateAndFetchCols table allColumns (cte, planVars) stringifyNum
  colValM <- asSingleObject colVals

  arrRelAffRows <- bool (withArrRels colValM) (return 0) $ null arrayRels
  let totAffRows = objRelAffRows + affRows + arrRelAffRows

  return (totAffRows, colValM)
  where
    AnnIns annObj table onConflict checkCond allColumns defaultValues = singleObjIns
    AnnInsObj columns objectRels arrayRels = annObj

    arrRelDepCols = flip getColInfos allColumns $
      concatMap (Map.keys . riMapping . _riRelInfo) arrayRels

    withArrRels colValM = do
      colVal <- onNothing colValM $ throw400 NotSupported cannotInsArrRelErr
      arrDepColsWithVal <- fetchFromColVals colVal arrRelDepCols
      arrInsARows <- forM arrayRels $ insertArrRel arrDepColsWithVal rjCtx planVars stringifyNum
      return $ sum arrInsARows

    asSingleObject = \case
      [] -> pure Nothing
      [r] -> pure $ Just r
      _ -> throw500 "more than one row returned"

    cannotInsArrRelErr =
      "cannot proceed to insert array relations since insert to table "
      <> table <<> " affects zero rows"

insertObjRel
  :: (HasVersion, MonadTx m, MonadIO m)
  => Seq.Seq Q.PrepArg
  -> RQL.MutationRemoteJoinCtx
  -> Bool
  -> ObjRelIns S.SQLExp
  -> m (Int, [(PGCol, S.SQLExp)])
insertObjRel planVars rjCtx stringifyNum objRelIns = do
  (affRows, colValM) <- insertObject singleObjIns [] rjCtx planVars stringifyNum
  colVal <- onNothing colValM $ throw400 NotSupported errMsg
  retColsWithVals <- fetchFromColVals colVal rColInfos
  let columns = flip mapMaybe (Map.toList mapCols) \(column, target) -> do
        value <- lookup target retColsWithVals
        Just (column, value)
  return (affRows, columns)
  where
    RelIns singleObjIns relInfo = objRelIns
    relName = riName relInfo
    table = riRTable relInfo
    mapCols = riMapping relInfo
    allCols = _aiTableCols singleObjIns
    rCols = Map.elems mapCols
    rColInfos = getColInfos rCols allCols
    errMsg = "cannot proceed to insert object relation "
             <> relName <<> " since insert to table "
             <> table <<> " affects zero rows"

insertArrRel
  :: (HasVersion, MonadTx m, MonadIO m)
  => [(PGCol, S.SQLExp)]
  -> RQL.MutationRemoteJoinCtx
  -> Seq.Seq Q.PrepArg
  -> Bool
  -> ArrRelIns S.SQLExp
  -> m Int
insertArrRel resCols rjCtx planVars stringifyNum arrRelIns = do
  let additionalColumns = flip mapMaybe resCols \(column, value) -> do
        target <- Map.lookup column mapping
        Just (target, value)
  resBS <- insertMultipleObjects multiObjIns additionalColumns rjCtx mutOutput planVars stringifyNum
  resObj <- decodeEncJSON resBS
  onNothing (Map.lookup ("affected_rows" :: T.Text) resObj) $
    throw500 "affected_rows not returned in array rel insert"
  where
    RelIns multiObjIns relInfo = arrRelIns
    mapping   = riMapping relInfo
    mutOutput = RQL.MOutMultirowFields [("affected_rows", RQL.MCount)]

-- | validate an insert object based on insert columns,
-- | insert object relations and additional columns from parent
validateInsert
  :: (MonadError QErr m)
  => [PGCol] -- ^ inserting columns
  -> [RelInfo] -- ^ object relation inserts
  -> [PGCol] -- ^ additional fields from parent
  -> m ()
validateInsert insCols objRels addCols = do
  -- validate insertCols
  unless (null insConflictCols) $ throw400 ValidationFailed $
    "cannot insert " <> showPGCols insConflictCols
    <> " columns as their values are already being determined by parent insert"

  forM_ objRels $ \relInfo -> do
    let lCols = Map.keys $ riMapping relInfo
        relName = riName relInfo
        relNameTxt = relNameToTxt relName
        lColConflicts = lCols `intersect` (addCols <> insCols)
    withPathK relNameTxt $ unless (null lColConflicts) $ throw400 ValidationFailed $
      "cannot insert object relation ship " <> relName
      <<> " as " <> showPGCols lColConflicts
      <> " column values are already determined"
  where
    insConflictCols = insCols `intersect` addCols


mkInsertQ
  :: MonadError QErr m
  => QualifiedTable
  -> Maybe (RQL.ConflictClauseP1 S.SQLExp)
  -> [(PGCol, S.SQLExp)]
  -> Map.HashMap PGCol S.SQLExp
  -> (AnnBoolExpSQL, Maybe AnnBoolExpSQL)
  -> m S.CTE
mkInsertQ table onConflictM insCols defVals (insCheck, updCheck) = do
  let sqlConflict = RQL.toSQLConflict table <$> onConflictM
      sqlExps = mkSQLRow defVals insCols
      valueExp = S.ValuesExp [S.TupleExp sqlExps]
      tableCols = Map.keys defVals
      sqlInsert =
        S.SQLInsert table tableCols valueExp sqlConflict
          . Just
          $ S.RetExp
            [ S.selectStar
            , S.Extractor
                (RQL.insertOrUpdateCheckExpr table onConflictM
                  (RQL.toSQLBoolExp (S.QualTable table) insCheck)
                  (fmap (RQL.toSQLBoolExp (S.QualTable table)) updCheck))
                Nothing
            ]
  pure $ S.CTEInsert sqlInsert

fetchFromColVals
  :: MonadError QErr m
  => ColumnValues TxtEncodedPGVal
  -> [PGColumnInfo]
  -> m [(PGCol, S.SQLExp)]
fetchFromColVals colVal reqCols =
  forM reqCols $ \ci -> do
    let valM = Map.lookup (pgiColumn ci) colVal
    val <- onNothing valM $ throw500 $ "column "
           <> pgiColumn ci <<> " not found in given colVal"
    let pgColVal = case val of
          TENull  -> S.SENull
          TELit t -> S.SELit t
    return (pgiColumn ci, pgColVal)

mkSQLRow :: Map.HashMap PGCol S.SQLExp -> [(PGCol, S.SQLExp)] -> [S.SQLExp]
mkSQLRow defVals withPGCol = map snd $
  flip map (Map.toList defVals) $
    \(col, defVal) -> (col,) $ fromMaybe defVal $ Map.lookup col withPGColMap
  where
    withPGColMap = Map.fromList withPGCol

decodeEncJSON :: (J.FromJSON a, QErrM m) => EncJSON -> m a
decodeEncJSON =
  either (throw500 . T.pack) decodeValue .
  J.eitherDecode . encJToLBS
