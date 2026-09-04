// WYSIWYG memo body editing (ADR-0006): a Word-like editor over the v1
// format set — 标题 H1–H3、加粗、斜体、删除线、行内代码、代码块、有序/无序
// 列表、待办勾选、引用、链接 — serialized to clean Markdown on save. The
// user never sees syntax symbols; Markdown appears only in storage.
//
// Content that leaves the v1 format set (tables, images, H4–H6, …) is
// displayed read-only, never silently degraded: round-trip losslessness is
// promised only inside the format set.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:super_editor/super_editor.dart';

/// Block types of the v1 format set, by attribution id. H4–H6 are
/// deliberately absent — a memo carrying them opens read-only (ADR-0006).
final _allowedBlockTypeIds = {
  paragraphAttribution.id,
  header1Attribution.id,
  header2Attribution.id,
  header3Attribution.id,
  blockquoteAttribution.id,
  codeAttribution.id,
};

/// Inline styles of the v1 format set, by attribution id. Links are
/// LinkAttribution and allowed separately.
const _allowedInlineIds = {'bold', 'italics', 'strikethrough', 'code'};

/// A parsed memo body: the document the editor renders, plus whether the
/// content stays inside the v1 format set.
class _ParsedBody {
  final MutableDocument document;
  final bool withinFormatSet;

  const _ParsedBody(this.document, this.withinFormatSet);
}

/// Parses stored Markdown into an editor document. Node ids are rebuilt as
/// deterministic `n0, n1, …` so the surface is addressable (and testable)
/// without touching UUID internals.
_ParsedBody _parseBody(String markdown) {
  final raw = deserializeMarkdownToDocument(markdown);

  var within = true;
  final rebuilt = <DocumentNode>[];
  for (var i = 0; i < raw.nodeCount && within; i++) {
    final node = raw.getNodeAt(i)!;
    if (node is! TextNode || !_withinInlineSet(node.text)) {
      within = false;
      break;
    }
    final id = 'n$i';
    if (node is ParagraphNode) {
      final blockType = node.getMetadataValue('blockType') as Attribution?;
      if (!_allowedBlockTypeIds.contains(blockType?.id)) {
        within = false;
        break;
      }
      rebuilt.add(ParagraphNode(
        id: id,
        text: node.text,
        indent: node.indent,
        metadata: {'blockType': blockType},
      ));
    } else if (node is ListItemNode) {
      rebuilt.add(ListItemNode(
        id: id,
        itemType: node.type,
        text: node.text,
        indent: node.indent,
      ));
    } else if (node is TaskNode) {
      rebuilt.add(TaskNode(
        id: id,
        text: node.text,
        isComplete: node.isComplete,
        indent: node.indent,
      ));
    } else {
      // Images, horizontal rules, tables and anything unknown.
      within = false;
      break;
    }
  }

  return _ParsedBody(
    within ? MutableDocument(nodes: rebuilt) : raw,
    within,
  );
}

bool _withinInlineSet(AttributedText text) {
  final length = text.toPlainText().length;
  final seen = <Attribution>{};
  for (var offset = 0; offset <= length; offset++) {
    seen.addAll(text.spans.getAllAttributionsAt(offset));
  }
  return seen.every(
    (a) => a is LinkAttribution || _allowedInlineIds.contains(a.id),
  );
}

/// Notifies on every document edit — the Editor's listener signature is
/// event-based, this adapts it to a plain Listenable for the toolbar.
class _DocumentChanges with ChangeNotifier implements EditListener {
  _DocumentChanges(Editor editor) : _editor = editor {
    editor.addListener(this);
  }

  final Editor _editor;

  @override
  void onEdit(List<EditEvent> changeList) => notifyListeners();

  @override
  void dispose() {
    _editor.removeListener(this);
    super.dispose();
  }
}

/// Owns the editor pipeline for one open memo body: the document, the edit
/// history, the toolbar's format operations, and the Markdown view of the
/// current content.
class MeridianEditorController {
  MeridianEditorController(String initialMarkdown)
      : _parsed = _parseBody(initialMarkdown) {
    document = _parsed.document;
    composer = MutableDocumentComposer();
    editor = Editor(
      editables: {
        Editor.documentKey: document,
        Editor.composerKey: composer,
      },
      requestHandlers: List.from(defaultRequestHandlers),
      // Curated for the v1 format set: typed `# ` prefixes become headings
      // but cap at H3, and the image / horizontal-rule / em-dash conversions
      // are gone, so nothing beyond the format set can be typed in.
      reactionPipeline: [
        UpdateComposerTextStylesReaction(),
        const LinkifyReaction(),
        HeaderConversionReaction(3),
        const UnorderedListItemConversionReaction(),
        const OrderedListItemConversionReaction(),
        const BlockquoteConversionReaction(),
        UpdateSubTaskIndentAfterTaskDeletionReaction(),
      ],
      isHistoryEnabled: true,
    );
  }

  final _ParsedBody _parsed;
  late final MutableDocument document;
  late final Editor editor;
  late final MutableDocumentComposer composer;
  late final _DocumentChanges _documentChanges = _DocumentChanges(editor);

  bool get withinFormatSet => _parsed.withinFormatSet;

  /// Fires on every document or selection change — the toolbar listens to
  /// it for its active states.
  Listenable get changes =>
      Listenable.merge([_documentChanges, composer, composer.preferences]);

  /// The current content as clean Markdown.
  String get markdown => serializeDocumentToMarkdown(document);

  /// The text node the selection starts in, if any.
  TextNode? get selectedNode {
    final selection = composer.selection;
    if (selection == null) return null;
    final node = document.getNodeById(selection.base.nodeId);
    return node is TextNode ? node : null;
  }

  /// The link covering the expanded selection, if the whole selection
  /// carries one.
  LinkAttribution? get selectedLink {
    final selection = composer.selection;
    if (selection == null || selection.isCollapsed) return null;
    if (selection.base.nodeId != selection.extent.nodeId) return null;
    final node = document.getNodeById(selection.base.nodeId);
    if (node is! TextNode) return null;
    final start = (selection.base.nodePosition as TextNodePosition).offset;
    final end = (selection.extent.nodePosition as TextNodePosition).offset;
    // Attribution ranges are end-exclusive; the "throughout" query is not.
    return node.text
        .getAllAttributionsThroughout(
            SpanRange(min(start, end), max(start, end) - 1))
        .whereType<LinkAttribution>()
        .firstOrNull;
  }

  // Block formats apply to the caret's node: tapping the active style again
  // returns the node to a plain paragraph, Word-style.
  void toggleBlockType(Attribution type) {
    final node = selectedNode;
    if (node == null) return;
    if (node is ParagraphNode) {
      final current = node.getMetadataValue('blockType') as Attribution?;
      editor.execute([
        ChangeParagraphBlockTypeRequest(
          nodeId: node.id,
          blockType: current == type ? paragraphAttribution : type,
        ),
      ]);
      return;
    }
    // List items and tasks become paragraphs carrying the block type.
    _replaceNode(
      node,
      ParagraphNode(
        id: node.id,
        text: node.text,
        indent: _indentOf(node),
        metadata: {'blockType': type},
      ),
    );
  }

  void toggleList(ListItemType type) {
    final node = selectedNode;
    if (node == null) return;
    if (node is ListItemNode && node.type == type) {
      _toParagraph(node);
      return;
    }
    _replaceNode(
      node,
      ListItemNode(
        id: node.id,
        itemType: type,
        text: node.text,
        indent: _indentOf(node),
      ),
    );
  }

  void toggleTodo() {
    final node = selectedNode;
    if (node == null) return;
    if (node is TaskNode) {
      _toParagraph(node);
      return;
    }
    _replaceNode(
      node,
      TaskNode(
        id: node.id,
        text: node.text,
        isComplete: false,
        indent: _indentOf(node),
      ),
    );
  }

  // With a collapsed caret the toggle styles what gets typed next; with an
  // expanded selection it styles the selection.
  void toggleInlineAttribution(Attribution attribution) {
    final selection = composer.selection;
    if (selection == null) return;
    if (selection.isCollapsed) {
      composer.preferences.toggleStyle(attribution);
      return;
    }
    editor.execute([
      ToggleTextAttributionsRequest(
        documentRange: selection,
        attributions: {attribution},
      ),
    ]);
  }

  bool hasInlineAttribution(Attribution attribution) {
    final selection = composer.selection;
    if (selection == null) return false;
    if (selection.isCollapsed) {
      return composer.preferences.currentAttributions.contains(attribution);
    }
    if (selection.base.nodeId != selection.extent.nodeId) return false;
    final node = document.getNodeById(selection.base.nodeId);
    if (node is! TextNode) return false;
    final start = (selection.base.nodePosition as TextNodePosition).offset;
    final end = (selection.extent.nodePosition as TextNodePosition).offset;
    // Attribution ranges are end-exclusive; the "throughout" query is not.
    return node.text
        .getAllAttributionsThroughout(
            SpanRange(min(start, end), max(start, end) - 1))
        .contains(attribution);
  }

  // The selection is gone by the time a link dialog closes (focus loss
  // clears it), so these apply to a range captured before opening it.
  void addLink(DocumentRange range, String url) {
    editor.execute([
      AddTextAttributionsRequest(
        documentRange: range,
        attributions: {LinkAttribution(url)},
      ),
    ]);
  }

  void removeLink(DocumentRange range, LinkAttribution link) {
    editor.execute([
      RemoveTextAttributionsRequest(
        documentRange: range,
        attributions: {link},
      ),
    ]);
  }

  static int _indentOf(TextNode node) => switch (node) {
        ParagraphNode(:final indent) => indent,
        ListItemNode(:final indent) => indent,
        TaskNode(:final indent) => indent,
        _ => 0,
      };

  void _replaceNode(DocumentNode oldNode, DocumentNode newNode) {
    editor.execute([
      ReplaceNodeRequest(existingNodeId: oldNode.id, newNode: newNode),
    ]);
  }

  void _toParagraph(TextNode node) {
    _replaceNode(
      node,
      ParagraphNode(id: node.id, text: node.text, indent: _indentOf(node)),
    );
  }

  void dispose() {
    _documentChanges.dispose();
    editor.dispose();
  }
}

/// The editable WYSIWYG body: a fixed toolbar applying the v1 format set
/// plus the document surface. Formats are applied to the current selection;
/// the buttons never steal the focus from the document.
class MeridianEditor extends StatefulWidget {
  final MeridianEditorController controller;

  const MeridianEditor({super.key, required this.controller});

  @override
  State<MeridianEditor> createState() => _MeridianEditorState();
}

class _MeridianEditorState extends State<MeridianEditor> {
  MeridianEditorController get _controller => widget.controller;

  // Stable across builds: SuperEditor ref-counts plugin attachments per
  // instance, so a fresh set literal on every build breaks its dispose.
  late final _plugins = {
    // `**bold**`-style wrapping syntax converts as you type and the symbols
    // disappear — no residue in the document.
    MarkdownInlineUpstreamSyntaxPlugin(),
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListenableBuilder(
          listenable: _controller.changes,
          builder: (context, _) => _buildToolbar(context),
        ),
        const Divider(height: 1),
        Expanded(
          child: SuperEditor(
            editor: _controller.editor,
            // Mouse-style gestures everywhere: taps and drags edit the
            // document like on a desktop, without the mobile floating
            // selection menu crowding the fixed toolbar.
            gestureMode: DocumentGestureMode.mouse,
            plugins: _plugins,
          ),
        ),
      ],
    );
  }

  Widget _buildToolbar(BuildContext context) {
    final node = _controller.selectedNode;
    final blockType = node is ParagraphNode
        ? (node.getMetadataValue('blockType') as Attribution?)?.id
        : null;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _blockButton('fmt_h1', Icons.title, '标题 1', header1Attribution,
              active: blockType == header1Attribution.id),
          _blockButton('fmt_h2', Icons.title, '标题 2', header2Attribution,
              active: blockType == header2Attribution.id),
          _blockButton('fmt_h3', Icons.title, '标题 3', header3Attribution,
              active: blockType == header3Attribution.id),
          _blockButton('fmt_paragraph', Icons.notes, '正文', paragraphAttribution,
              active: blockType == paragraphAttribution.id),
          _inlineButton('fmt_bold', Icons.format_bold, '加粗', boldAttribution),
          _inlineButton(
              'fmt_italic', Icons.format_italic, '斜体', italicsAttribution),
          _inlineButton('fmt_strike', Icons.format_strikethrough, '删除线',
              strikethroughAttribution),
          _inlineButton('fmt_code', Icons.code, '行内代码', codeAttribution),
          IconButton(
            key: const Key('fmt_ul'),
            tooltip: '无序列表',
            isSelected:
                node is ListItemNode && node.type == ListItemType.unordered,
            icon: const Icon(Icons.format_list_bulleted),
            onPressed: () =>
                _controller.toggleList(ListItemType.unordered),
          ),
          IconButton(
            key: const Key('fmt_ol'),
            tooltip: '有序列表',
            isSelected:
                node is ListItemNode && node.type == ListItemType.ordered,
            icon: const Icon(Icons.format_list_numbered),
            onPressed: () => _controller.toggleList(ListItemType.ordered),
          ),
          IconButton(
            key: const Key('fmt_todo'),
            tooltip: '待办',
            isSelected: node is TaskNode,
            icon: const Icon(Icons.checklist),
            onPressed: _controller.toggleTodo,
          ),
          _blockButton(
              'fmt_quote', Icons.format_quote, '引用', blockquoteAttribution,
              active: blockType == blockquoteAttribution.id),
          _blockButton('fmt_codeblock', Icons.data_object, '代码块',
              codeAttribution,
              active: blockType == codeAttribution.id),
          IconButton(
            key: const Key('fmt_link'),
            tooltip: '链接',
            icon: const Icon(Icons.link),
            onPressed: _editLink,
          ),
        ],
      ),
    );
  }

  IconButton _blockButton(
      String key, IconData icon, String tooltip, Attribution type,
      {required bool active}) {
    return IconButton(
      key: Key(key),
      tooltip: tooltip,
      isSelected: active,
      icon: Icon(icon),
      onPressed: () => _controller.toggleBlockType(type),
    );
  }

  IconButton _inlineButton(
      String key, IconData icon, String tooltip, Attribution attribution) {
    return IconButton(
      key: Key(key),
      tooltip: tooltip,
      isSelected: _controller.hasInlineAttribution(attribution),
      icon: Icon(icon),
      onPressed: () => _controller.toggleInlineAttribution(attribution),
    );
  }

  Future<void> _editLink() async {
    final selection = _controller.composer.selection;
    if (selection == null || selection.isCollapsed) return;
    final existing = _controller.selectedLink;
    // String: the URL to apply; the `remove` sentinel: strip the link; null:
    // cancelled.
    final result = await showDialog<Object>(
      context: context,
      builder: (context) => _LinkDialog(existingUrl: existing?.plainTextUri),
    );
    if (result == 'remove') {
      _controller.removeLink(selection, existing!);
      return;
    }
    if (result is! String) return;
    final trimmed = result.trim();
    if (trimmed.isEmpty) return;
    _controller.addLink(selection, trimmed);
  }
}

/// The link dialog; owns its text field's controller so it survives the
/// route's exit animation.
class _LinkDialog extends StatefulWidget {
  final String? existingUrl;

  const _LinkDialog({this.existingUrl});

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late final _field = TextEditingController(text: widget.existingUrl);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existingUrl == null ? '添加链接' : '编辑链接'),
      content: TextField(
        key: const Key('link_url_field'),
        controller: _field,
        autofocus: true,
        decoration: const InputDecoration(labelText: '链接地址'),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        if (widget.existingUrl != null)
          TextButton(
            key: const Key('link_remove'),
            onPressed: () => Navigator.of(context).pop('remove'),
            child: const Text('移除链接'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('link_apply'),
          onPressed: () => Navigator.of(context).pop(_field.text),
          child: const Text('应用'),
        ),
      ],
    );
  }
}

/// Read-only display for a memo whose body leaves the v1 format set
/// (tables and the like): rendered as it will be exported, never degraded,
/// with no editing affordances.
class MeridianDocumentReader extends StatelessWidget {
  final MeridianEditorController controller;

  const MeridianDocumentReader({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return SuperReader(
      editor: controller.editor,
      componentBuilders: [
        const MarkdownTableComponentBuilder(),
        ...readOnlyDefaultComponentBuilders,
      ],
    );
  }
}
