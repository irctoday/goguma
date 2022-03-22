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

	EditTopicDialog({ Key? key, required this.buffer }) : super(key: key);

	@override
	EditTopicDialogState createState() => EditTopicDialogState();
}

class EditTopicDialogState extends State<EditTopicDialog> {
	late final TextEditingController _topicController;

	@override
	void initState() {
		super.initState();
		_topicController = TextEditingController(text: widget.buffer.topic);
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
