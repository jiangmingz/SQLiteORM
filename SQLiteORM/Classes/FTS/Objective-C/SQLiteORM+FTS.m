//
//  SQLiteORM+FTS.m
//  SQLiteORM
//
//  Created by Valo on 2019/5/21.
//

#import <Foundation/Foundation.h>
#import "SQLiteORM+FTS.h"

#ifdef SQLITE_HAS_CODEC
#import "sqlite3.h"
#else
#import <sqlite3.h>
#endif

extern NSString * simplifiedString(NSString *);
extern NSString * traditionalString(NSString *);
extern NSArray * swift_tokenize(NSString *, int);
extern NSArray * swift_pinyinTokenize(NSString *, int, int);
extern NSArray * swift_numberTokenize(NSString *);

@implementation SQLiteORMToken
+ (instancetype)token:(NSString *)token len:(int)len start:(int)start end:(int)end
{
    SQLiteORMToken *tk = [SQLiteORMToken new];
    tk.token = token;
    tk.start = start;
    tk.len = len;
    tk.end = end;
    return tk;
}

- (NSString *)description {
    return _token;
}

- (NSString *)debugDescription {
    return [NSString stringWithFormat:@"'%@',%@,%@,%@", _token, @(_len), @(_start), @(_end)];
}

@end

//MARK: - FTS3
typedef struct sqlite3_tokenizer_module   sqlite3_tokenizer_module;
typedef struct sqlite3_tokenizer          sqlite3_tokenizer;
typedef struct sqlite3_tokenizer_cursor   sqlite3_tokenizer_cursor;

struct sqlite3_tokenizer_module {
    int iVersion;
    int (*xCreate)(
        int               argc,                                  /* Size of argv array */
        const char *const *argv,                                 /* Tokenizer argument strings */
        sqlite3_tokenizer **ppTokenizer                          /* OUT: Created tokenizer */
        );
    int (*xDestroy)(sqlite3_tokenizer *pTokenizer);
    int (*xOpen)(
        sqlite3_tokenizer *pTokenizer,                           /* Tokenizer object */
        const char *pInput, int nBytes,                          /* Input buffer */
        sqlite3_tokenizer_cursor **ppCursor                      /* OUT: Created tokenizer cursor */
        );
    int (*xClose)(sqlite3_tokenizer_cursor *pCursor);
    int (*xNext)(
        sqlite3_tokenizer_cursor *pCursor,                       /* Tokenizer cursor */
        const char **ppToken, int *pnBytes,                      /* OUT: Normalized text for token */
        int *piStartOffset,                                      /* OUT: Byte offset of token in input buffer */
        int *piEndOffset,                                        /* OUT: Byte offset of end of token in input buffer */
        int *piPosition                                          /* OUT: Number of tokens returned before this one */
        );
    int (*xLanguageid)(sqlite3_tokenizer_cursor *pCsr, int iLangid);
    const char *xName;
    int xMethod;
};

struct sqlite3_tokenizer {
    const sqlite3_tokenizer_module *pModule;  /* The module for this tokenizer */
};

struct sqlite3_tokenizer_cursor {
    sqlite3_tokenizer *pTokenizer;            /* Tokenizer for this cursor. */
};

typedef struct vv_fts3_tokenizer {
    sqlite3_tokenizer base;
    char locale[16];
    int pinyinMaxLen;
    bool tokenNum;
    bool transfrom;
} vv_fts3_tokenizer;

typedef struct vv_fts3_tokenizer_cursor {
    sqlite3_tokenizer_cursor base;  /* base cursor */
    const char *pInput;             /* input we are tokenizing */
    int nBytes;                     /* size of the input */
    int iToken;                     /* index of current token*/
    int nToken;                     /* count of token */
    CFArrayRef tokens;
} vv_fts3_tokenizer_cursor;

static int fts3_register_tokenizer(
    sqlite3                        *db,
    char                           *zName,
    const sqlite3_tokenizer_module *p
    )
{
    int rc;
    sqlite3_stmt *pStmt;
    const char *zSql = "SELECT fts3_tokenizer(?, ?)";

    sqlite3_db_config(db, SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER, 1, 0);

    rc = sqlite3_prepare_v2(db, zSql, -1, &pStmt, 0);
    if (rc != SQLITE_OK) {
        return rc;
    }

    sqlite3_bind_text(pStmt, 1, zName, -1, SQLITE_STATIC);
    sqlite3_bind_blob(pStmt, 2, &p, sizeof(p), SQLITE_STATIC);
    sqlite3_step(pStmt);

    return sqlite3_finalize(pStmt);
}

static int vv_fts3_create(
    int argc, const char *const *argv,
    sqlite3_tokenizer **ppTokenizer
    )
{
    vv_fts3_tokenizer *tok;
    UNUSED_PARAM(argc);
    UNUSED_PARAM(argv);

    tok = (vv_fts3_tokenizer *)sqlite3_malloc(sizeof(*tok));
    if (tok == NULL) return SQLITE_NOMEM;
    memset(tok, 0, sizeof(*tok));

    memset(tok->locale, 0x0, 16);
    tok->pinyinMaxLen = 0;
    tok->tokenNum = false;
    tok->transfrom = false;

    for (int i = 0; i < MIN(2, argc); i++) {
        const char *arg = argv[i];
        uint32_t flag = (uint32_t)atol(arg);
        if (flag > 0) {
            tok->pinyinMaxLen = flag & TokenizerParamPinyin;
            tok->tokenNum = (flag & TokenizerParamNumber) > 0;
            tok->transfrom = (flag & TokenizerParamTransform) > 0;
        } else {
            strncpy(tok->locale, arg, 15);
        }
    }

    *ppTokenizer = &tok->base;
    return SQLITE_OK;
}

static int vv_fts3_destroy(sqlite3_tokenizer *pTokenizer)
{
    sqlite3_free(pTokenizer);
    return SQLITE_OK;
}

static int vv_fts3_open(
    sqlite3_tokenizer *pTokenizer,                                                  /* The tokenizer */
    const char *pInput, int nBytes,                                                 /* String to be tokenized */
    sqlite3_tokenizer_cursor **ppCursor                                             /* OUT: Tokenization cursor */
    )
{
    UNUSED_PARAM(pTokenizer);
    if (pInput == 0) return SQLITE_ERROR;

    vv_fts3_tokenizer_cursor *c;
    c = (vv_fts3_tokenizer_cursor *)sqlite3_malloc(sizeof(*c));
    if (c == NULL) return SQLITE_NOMEM;

    const sqlite3_tokenizer_module *module = pTokenizer->pModule;
    int method = module->xMethod;
    int nInput = (pInput == 0) ? 0 : (nBytes < 0 ? (int)strlen(pInput) : nBytes);

    vv_fts3_tokenizer *tok = (vv_fts3_tokenizer *)pTokenizer;

    NSString *ocString = [NSString stringWithUTF8String:pInput].lowercaseString;
    if (tok->transfrom) {
        ocString = simplifiedString(ocString);
    }

    NSMutableArray *array = [NSMutableArray arrayWithCapacity:0];
    [array addObjectsFromArray:swift_tokenize(ocString, method)];

    if (tok->tokenNum) {
        [array addObjectsFromArray:swift_numberTokenize(ocString)];
    }
    if (tok->pinyinMaxLen > 0 && nInput < tok->pinyinMaxLen) {
        [array addObjectsFromArray:swift_pinyinTokenize(ocString, 0, nInput)];
    }

    c->pInput = pInput;
    c->nBytes = nInput;
    c->iToken = 0;
    c->nToken = (int)array.count;
    c->tokens = (__bridge_retained CFArrayRef)array;

    *ppCursor = &c->base;
    return SQLITE_OK;
}

static int vv_fts3_close(sqlite3_tokenizer_cursor *pCursor)
{
    vv_fts3_tokenizer_cursor *c = (vv_fts3_tokenizer_cursor *)pCursor;
    CFRelease(c->tokens);
    sqlite3_free(c);
    return SQLITE_OK;
}

static int vv_fts3_next(
    sqlite3_tokenizer_cursor *pCursor,                                                  /* Cursor returned by vv_fts3_open */
    const char               **ppToken,                                                 /* OUT: *ppToken is the token text */
    int                      *pnBytes,                                                  /* OUT: Number of bytes in token */
    int                      *piStartOffset,                                            /* OUT: Starting offset of token */
    int                      *piEndOffset,                                              /* OUT: Ending offset of token */
    int                      *piPosition                                                /* OUT: Position integer of token */
    )
{
    vv_fts3_tokenizer_cursor *c = (vv_fts3_tokenizer_cursor *)pCursor;
    NSArray *array = (__bridge NSArray *)(c->tokens);
    if (array.count == 0 || c->iToken == array.count) return SQLITE_DONE;
    SQLiteORMToken *t = array[c->iToken];
    *ppToken = t.token.UTF8String;
    *pnBytes = t.len;
    *piStartOffset = t.start;
    *piEndOffset = t.end;
    *piPosition = c->iToken++;
    return SQLITE_OK;
}

//MARK: - FTS5

static fts5_api * fts5_api_from_db(sqlite3 *db)
{
    fts5_api *pRet = 0;
    sqlite3_stmt *pStmt = 0;

    if (SQLITE_OK == sqlite3_prepare(db, "SELECT fts5(?1)", -1, &pStmt, 0) ) {
#ifdef SQLITE_HAS_CODEC
        sqlite3_bind_pointer(pStmt, 1, (void *)&pRet, "fts5_api_ptr", NULL);
        sqlite3_step(pStmt);
#else
        if (@available(macOS 10.14, iOS 12.0, watchOS 5.0, tvOS 12.0, *)) {
            sqlite3_bind_pointer(pStmt, 1, (void *)&pRet, "fts5_api_ptr", NULL);
            sqlite3_step(pStmt);
        }
#endif
    }
    sqlite3_finalize(pStmt);
    return pRet;
}

typedef struct Fts5VVTokenizer Fts5VVTokenizer;
struct Fts5VVTokenizer {
    char locale[16];
    int pinyinMaxLen;
    bool tokenNum;
    bool transfrom;
    int method;
};

static void vv_fts5_xDelete(Fts5Tokenizer *p)
{
    sqlite3_free(p);
}

static int vv_fts5_xCreate(
    void *pUnused,
    const char **azArg, int nArg,
    Fts5Tokenizer **ppOut
    )
{
    Fts5VVTokenizer *tok = sqlite3_malloc(sizeof(Fts5VVTokenizer));
    if (!tok) return SQLITE_NOMEM;

    memset(tok->locale, 0x0, 16);
    tok->pinyinMaxLen = 0;
    tok->tokenNum = false;
    tok->transfrom = false;

    for (int i = 0; i < MIN(2, nArg); i++) {
        const char *arg = azArg[i];
        uint32_t flag = (uint32_t)atol(arg);
        if (flag > 0) {
            tok->pinyinMaxLen = flag & TokenizerParamPinyin;
            tok->tokenNum = (flag & TokenizerParamNumber) > 0;
            tok->transfrom = (flag & TokenizerParamTransform) > 0;
        } else {
            strncpy(tok->locale, arg, 15);
        }
    }

    int method = *(int *)pUnused;
    tok->method = method;
    *ppOut = (Fts5Tokenizer *)tok;
    return SQLITE_OK;
}

static int vv_fts5_xTokenize(
    Fts5Tokenizer *pTokenizer,
    void *pCtx,
    int iUnused,
    const char *pText, int nText,
    int (*xToken)(void *, int, const char *, int nToken, int iStart, int iEnd)
    )
{
    UNUSED_PARAM(iUnused);
    UNUSED_PARAM(pText);
    if (pText == 0) return SQLITE_OK;

    __block int rc = SQLITE_OK;
    Fts5VVTokenizer *tok = (Fts5VVTokenizer *)pTokenizer;
    int nInput = (pText == 0) ? 0 : (nText < 0 ? (int)strlen(pText) : nText);

    NSString *ocString = [NSString stringWithUTF8String:pText].lowercaseString;
    if (tok->transfrom) {
        ocString = simplifiedString(ocString);
    }
    int method = tok->method;

    NSMutableArray *array = [NSMutableArray arrayWithCapacity:0];
    [array addObjectsFromArray:swift_tokenize(ocString, method)];

    if (tok->tokenNum) {
        [array addObjectsFromArray:swift_numberTokenize(ocString)];
    }
    if (tok->pinyinMaxLen > 0 && nInput < tok->pinyinMaxLen) {
        [array addObjectsFromArray:swift_pinyinTokenize(ocString, 0, nInput)];
    }

    for (SQLiteORMToken *tk in array) {
        rc = xToken(pCtx, iUnused, tk.token.UTF8String, tk.len, tk.start, tk.end);
        if (rc != SQLITE_OK) break;
    }

    if (rc == SQLITE_DONE) rc = SQLITE_OK;
    return rc;
}

// MAKR: -
static inline BOOL check(int resultCode)
{
    switch (resultCode) {
        case SQLITE_OK:
        case SQLITE_ROW:
        case SQLITE_DONE:
            return YES;

        default:
            return NO;
    }
}

BOOL SQLiteORMRegisterEnumerator(sqlite3 *db, int method, NSString *tokenizerName)
{
    char *name = (char *)tokenizerName.UTF8String;

    sqlite3_tokenizer_module *module;
    module = (sqlite3_tokenizer_module *)sqlite3_malloc(sizeof(*module));
    module->iVersion = 0;
    module->xCreate = vv_fts3_create;
    module->xDestroy = vv_fts3_destroy;
    module->xOpen = vv_fts3_open;
    module->xClose = vv_fts3_close;
    module->xNext = vv_fts3_next;
    module->xName = name;
    module->xMethod = method;
    int rc = fts3_register_tokenizer(db, name, module);

    BOOL ret =  check(rc);
    if (!ret) return ret;

    fts5_api *pApi = fts5_api_from_db(db);
    if (!pApi) return NO;
    fts5_tokenizer *tokenizer;
    tokenizer = (fts5_tokenizer *)sqlite3_malloc(sizeof(*tokenizer));
    tokenizer->xCreate = vv_fts5_xCreate;
    tokenizer->xDelete = vv_fts5_xDelete;
    tokenizer->xTokenize = vv_fts5_xTokenize;

    int *context = malloc(sizeof(int));
    *context = (int)method;

    rc = pApi->xCreateTokenizer(pApi,
                                name,
                                (void *)context,
                                tokenizer,
                                0);
    return check(rc);
}

int SQLiteORMFindEnumerator(sqlite3 *db, NSString *tokenizerName)
{
    fts5_api *pApi = fts5_api_from_db(db);
    if (!pApi) return 0xFFFFFFFF;

    void *pUserdata = 0;
    fts5_tokenizer *tokenizer;
    tokenizer = (fts5_tokenizer *)sqlite3_malloc(sizeof(*tokenizer));
    int rc = pApi->xFindTokenizer(pApi, tokenizerName.UTF8String, &pUserdata, tokenizer);
    if (rc != SQLITE_OK) return 0xFFFFFFFF;

    return *(int *)pUserdata;
}

/*
// MARK: -
static NSArray<SQLiteORMToken *> * tokenize(NSString *source, BOOL pinyin, SQLiteORMXEnumerator enumerator);

static NSAttributedString * highlightOne(NSString *source,
                                         int pyMaxLen,
                                         SQLiteORMXEnumerator enumerator,
                                         NSArray<SQLiteORMToken *> *keywordTokens,
                                         NSDictionary<NSAttributedStringKey, id> *attributes);

NSArray<NSAttributedString *> * SQLiteORMHighlight(NSArray *objects,
                                                   NSString *field,
                                                   NSString *keyword,
                                                   int pinyinMaxLen,
                                                   SQLiteORMXEnumerator enumerator,
                                                   NSDictionary<NSAttributedStringKey, id> *attributes)
{
    NSArray *keywordTokens = tokenize(keyword, NO, enumerator);
    int pymlen = pinyinMaxLen >= 0 ? : TOKEN_PINYIN_MAX_LENGTH;

    NSMutableArray *results = [NSMutableArray arrayWithCapacity:objects.count];
    for (NSObject *obj in objects) {
        NSString *source = [obj valueForKey:field];
        NSAttributedString *attrText = highlightOne(source, pymlen, enumerator, keywordTokens, attributes);
        [results addObject:attrText];
    }
    return results;
}

static NSArray<SQLiteORMToken *> * tokenize(NSString *source, BOOL pinyin, SQLiteORMXEnumerator enumerator)
{
    const char *pText = source.UTF8String ? : "";
    int nText = (int)strlen(pText);

    if (nText == 0) {
        return @[];
    }

    if (!enumerator) {
        SQLiteORMToken *ormToken = [SQLiteORMToken token:source len:nText start:0 end:nText];
        return @[ormToken];
    }

    __block NSMutableArray<SQLiteORMToken *> *results = [NSMutableArray arrayWithCapacity:0];

    SQLiteORMXTokenHandler handler = ^(const char *token, int len, int start, int end) {
        NSString *string = [[NSString alloc] initWithBytes:token length:len encoding:NSUTF8StringEncoding];
        SQLiteORMToken *ormToken = [SQLiteORMToken token:string len:len start:start end:end];
        [results addObject:ormToken];
        return YES;
    };
    enumerator(pText, nText, "", pinyin, handler);
    return results;
}

static NSAttributedString * highlightOne(NSString *source,
                                         int pyMaxLen,
                                         SQLiteORMXEnumerator enumerator,
                                         NSArray<SQLiteORMToken *> *keywordTokens,
                                         NSDictionary<NSAttributedStringKey, id> *attributes)
{
    const char *pText = source.UTF8String;

    if (!pText) {
        return [[NSAttributedString alloc] init];
    }

    if (!enumerator) {
        return [[NSAttributedString alloc] initWithString:source];
    }

    int nText = (int)strlen(pText);
    __block char *tokenized = (char *)malloc(nText + 1);
    memset(tokenized, 0x0, nText + 1);

    SQLiteORMXTokenHandler handler = ^(const char *token, int len, int start, int end) {
        for (SQLiteORMToken *kwToken in keywordTokens) {
            if (strncmp(token, kwToken.token.UTF8String, kwToken.len) != 0) continue;
            memcpy(tokenized + start, pText + start, end - start);
        }
        return YES;
    };

    enumerator(pText, nText, "", nText < pyMaxLen, handler);

    char *remained = (char *)malloc(nText + 1);
    strncpy(remained, pText, nText);
    remained[nText] = 0x0;
    for (int i = 0; i < nText + 1; i++) {
        if (tokenized[i] != 0) {
            memset(remained + i, 0x0, 1);
        }
    }
    NSMutableAttributedString *attrText = [[NSMutableAttributedString alloc] init];
    int pos = 0;
    while (pos < nText) {
        if (remained[pos] != 0x0) {
            NSString *str = [NSString stringWithUTF8String:(remained + pos)];
            [attrText appendAttributedString:[[NSAttributedString alloc] initWithString:str]];
            pos += strlen(remained + pos);
        } else {
            NSString *str = [NSString stringWithUTF8String:(tokenized + pos)];
            [attrText appendAttributedString:[[NSAttributedString alloc] initWithString:str attributes:attributes]];
            pos += strlen(tokenized + pos);
        }
    }
    free(remained);
    free(tokenized);

    return attrText;
}
 */
