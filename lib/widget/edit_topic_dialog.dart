import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../client_controller.dart';
import '../models.dart';

class EditTopicDialog extends StatefulWidget {
	final BufferModel buffer;

	static void show(BuildContext context, BufferModel buffer) {
		showDialog<void>(context: context, builder: (context) {
			return EditTopicDialog(buffer: buffer);
		});
	}

	const EditTopicDialog({ Key? key, required this.buffer }) : super(key: key);

	@override
	EditTopicDialogState createState() => EditTopicDialogState();
}

class EditTopicDialogState extends State<EditTopicDialog> {
	late final TextEditingController _topicController;
	late final int? _topicLen;

	@override
	void initState() {
		super.initState();
		_topicController = TextEditingController(text: widget.buffer.topic);

		var client = context.read<ClientProvider>().get(widget.buffer.network);
		_topicLen = client.isupport.topicLen;
	}

	void _submit() {
		Navigator.pop(context);

		String? topic;
		if (_topicController.text != '') {
			topic = _topicController.text;
		}

		var client = context.read<ClientProvider>().get(widget.buffer.network);
		client.setTopic(widget.buffer.name, topic).ignore();
	}

	@override
	Widget build(BuildContext context) {
		return AlertDialog(
			title: Text('Edit topic for ${widget.buffer.name}'),
			content: TextFormField(
				controller: _topicController,
				decoration: InputDecoration(hintText: 'Topic'),
				autofocus: true,
				maxLines: null,
				maxLength: _topicLen,
				keyboardType: TextInputType.text, // disallows newlines
				onFieldSubmitted: (_) {
					_submit();
				},
			),
			actions: [
				TextButton(
					child: Text('Cancel'),
					onPressed: () {
						Navigator.pop(context);
					},
				),
				ElevatedButton(
					child: Text('Save'),
					onPressed: () {
						_submit();
					},
				),
			],
		);
	}
}
