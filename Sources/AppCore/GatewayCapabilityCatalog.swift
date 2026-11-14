import Foundation

public enum GatewayCapabilityCatalog {
  public static func commands(for role: GatewayRole) -> Set<String> {
    switch (role.service, role.accessMode) {
    case (.docs, .read):
      ["document get"]
    case (.docs, .write):
      ["document create", "document batch-update"]
    case (.sheets, .read):
      [
        "spreadsheet get", "spreadsheet get-by-data-filter",
        "values get", "values batch-get", "values batch-get-by-data-filter",
        "developer-metadata get", "developer-metadata search"
      ]
    case (.sheets, .write):
      [
        "spreadsheet create", "spreadsheet batch-update", "sheet copy-to",
        "values append", "values update", "values clear", "values batch-update",
        "values batch-clear", "values batch-clear-by-data-filter", "values batch-update-by-data-filter"
      ]
    case (.drive, .read):
      [
        "about get", "changes start-token", "changes list", "shared-drives list", "shared-drives get",
        "files list", "files get", "files download", "files export",
        "permissions list", "permissions get", "comments list", "comments get",
        "replies list", "replies get", "revisions list", "revisions get", "revisions download"
      ]
    case (.drive, .write):
      [
        "folders create", "files upload", "files copy", "files replace-content", "files rename", "files move",
        "files trash", "files untrash", "permissions create", "permissions update", "permissions delete",
        "comments create", "comments update", "comments delete",
        "replies create", "replies update", "replies delete", "revisions update"
      ]
    }
  }

  public static let docsBatchUpdateRequests: Set<String> = [
    "addDocumentTab", "createFooter", "createFootnote", "createHeader", "createNamedRange",
    "createParagraphBullets", "deleteContentRange", "deleteFooter", "deleteHeader", "deleteNamedRange",
    "deleteParagraphBullets", "deletePositionedObject", "deleteTab", "deleteTableColumn", "deleteTableRow",
    "insertDate", "insertInlineImage", "insertPageBreak", "insertPerson", "insertRichLink",
    "insertSectionBreak", "insertTable", "insertTableColumn", "insertTableRow", "insertText",
    "mergeTableCells", "pinTableHeaderRows", "replaceAllText", "replaceImage", "replaceNamedRangeContent",
    "unmergeTableCells", "updateDocumentStyle", "updateDocumentTabProperties", "updateNamedStyle",
    "updateParagraphStyle", "updateSectionStyle", "updateTableCellStyle", "updateTableColumnProperties",
    "updateTableRowStyle", "updateTextStyle"
  ]

  public static let sheetsBatchUpdateRequests: Set<String> = [
    "addBanding", "addChart", "addConditionalFormatRule", "addDataSource", "addDimensionGroup",
    "addFilterView", "addNamedRange", "addProtectedRange", "addSheet", "addSlicer", "addTable",
    "appendCells", "appendDimension", "autoFill", "autoResizeDimensions", "cancelDataSourceRefresh",
    "clearBasicFilter", "copyPaste", "createDeveloperMetadata", "cutPaste", "deleteBanding",
    "deleteConditionalFormatRule", "deleteDataSource", "deleteDeveloperMetadata", "deleteDimension",
    "deleteDimensionGroup", "deleteDuplicates", "deleteEmbeddedObject", "deleteFilterView", "deleteNamedRange",
    "deleteProtectedRange", "deleteRange", "deleteSheet", "deleteTable", "duplicateFilterView", "duplicateSheet",
    "findReplace", "insertDimension", "insertRange", "mergeCells", "moveDimension", "pasteData",
    "randomizeRange", "refreshDataSource", "repeatCell", "setBasicFilter", "setDataValidation", "sortRange",
    "textToColumns", "trimWhitespace", "unmergeCells", "updateBanding", "updateBorders", "updateCells",
    "updateChartSpec", "updateConditionalFormatRule", "updateDataSource", "updateDeveloperMetadata",
    "updateDimensionGroup", "updateDimensionProperties", "updateEmbeddedObjectBorder",
    "updateEmbeddedObjectPosition", "updateFilterView", "updateNamedRange", "updateProtectedRange",
    "updateSheetProperties", "updateSlicerSpec", "updateSpreadsheetProperties", "updateTable"
  ]
}
