import 'package:flutter/material.dart';

typedef JoinDialogCallback(String);

class JoinDialog extends StatefulWidget {
	final JoinDialogCallback? onSubmit;

	JoinDialog({ Key? key, this.onSubmit }) : super(key: key);

	@override
	JoinDialogState createState() => JoinDialogState();
}

class JoinDialogState extends State<JoinDialog> {
	TextEditingController nameController = TextEditingController(text: '#');

	void submit(BuildContext context) {
		widget.onSubmit?.call(nameController.text);
		Navigator.pop(context);
	}

	@override
	void dispose() {
		nameController.dispose();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		return AlertDialog(
			title: Text('Join channel'),
			content: TextField(
				controller: nameController,
				decoration: InputDecoration(hintText: 'Name'),
				autofocus: true,
				onSubmitted: (_) {
					submit(context);
				},
			),
			actions: [
				FlatButton(
					child: Text('Cancel'),
					onPressed: () {
						Navigator.pop(context);
					},
				),
				ElevatedButton(
					child: Text('Join'),
					onPressed: () {
						submit(context);
					},
				),
			],
		);
	}
}
